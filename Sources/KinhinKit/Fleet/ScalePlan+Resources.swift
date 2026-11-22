import Foundation

extension ScalePlan {
    static func reservation(runtime: RuntimeID, containerPool: String?, input: Input) -> VMResourceReservation? {
        guard let budget = input.resources else { return nil }
        if runtime == .appleContainer, !input.containerPools.isEmpty {
            let name = containerPool ?? input.defaultContainerPool
            guard let shape = input.containerPools[name] else { return nil }
            return VMResourceReservation(cpu: shape.cpus, memoryGB: shape.memoryGB)
        }
        return budget.shapes[runtime]
    }

    static func resourceFits(runtime: RuntimeID, containerPool: String?, records: [VMRecord], input: Input) -> Bool {
        guard let budget = input.resources else { return true }
        guard let shape = reservation(runtime: runtime, containerPool: containerPool, input: input), shape.isValid
        else {
            return false
        }
        // Keep deleting and failed instances charged until removal from the
        // store proves teardown completed. Add simulated slots exactly once.
        let original = Set(input.records.map(\.id))
        let all = input.records + records.filter { !original.contains($0.id) }
        var cpu = 0
        var memory = 0
        for record in all {
            // A legacy/adopted instance's shape is unknown. Do not assume that
            // a config reload resized it: hold the whole budget until it exits.
            let allocation = record.resourceReservation.flatMap { $0.isValid ? $0 : nil } ?? budget.capacity
            cpu += allocation.cpu
            memory += allocation.memoryGB
        }
        return cpu + shape.cpu <= budget.capacity.cpu && memory + shape.memoryGB <= budget.capacity.memoryGB
    }

    static func selectRuntimeForAdmission(
        unmet: [RuntimeID: Int], active: [RuntimeID: Int], caps: [RuntimeID: Int], input: Input
    ) -> RuntimeID? {
        if input.resources != nil {
            // Return a borrowed share when its owner has runnable demand.
            // Busy Tart jobs finish before their CPU or memory can be reassigned.
            let entitled = unmet.filter {
                $0.key != input.defaultRuntime && $0.value > 0 && input.existingPools.contains($0.key)
                    && (active[$0.key] ?? 0) < (caps[$0.key] ?? Int.max)
            }
            if !entitled.isEmpty,
                let selected = selectRuntime(
                    unmet: entitled, active: active, caps: caps, fallback: input.defaultRuntime,
                    poolExists: input.existingPools.contains)
            {
                return selected
            }
        }
        return selectRuntime(
            unmet: unmet, active: active, caps: caps, fallback: input.defaultRuntime,
            poolExists: input.existingPools.contains)
    }

    /// Leave a free slot open if a queued non-Tart job can run once the current Tart guests exit.
    /// Otherwise a steady stream of small Tart jobs could prevent a larger Linux job from ever fitting.
    static func waitsForTartToDrain(
        runtime: RuntimeID, records: [VMRecord], totals: [String: Int], input: Input
    ) -> Bool {
        guard input.resources != nil, runtime != input.defaultRuntime else { return false }
        var drained = input
        drained.records = input.records.filter { pool(of: $0, input: input) != .tart }
        guard drained.records.count < input.records.count else { return false }
        let remaining = records.filter { pool(of: $0, input: input) != .tart }
        var namedPool: String?
        if runtime == .appleContainer, !input.containerPools.isEmpty {
            guard let picked = chooseContainerPool(records: remaining, input: drained),
                containerPoolUnmet(picked, records: remaining, input: drained) > 0
            else { return false }
            namedPool = picked
        }
        return resourceFits(runtime: runtime, containerPool: namedPool, records: remaining, input: drained)
            && accountForAdmission(
                runtime: runtime, containerPool: namedPool, records: remaining,
                totals: totals, input: drained) != nil
    }

    /// Request oldest-first releases of idle Tart slots only when the capacity
    /// they free would let waiting Linux work start on a later pass.
    /// The engine rechecks each runner with its forge before deleting it.
    static func idleTartToRelease(
        active: [VMRecord], cap: Int, reserved: [RuntimeID: Int], input: Input
    ) -> [String] {
        guard unmetByPool(records: active, input: input).keys.contains(where: { $0 != .tart }) else { return [] }
        let verifiable = Set(
            active.compactMap { record in
                record.platform.map(input.attached.contains) == true ? record.id : nil
            })
        let candidates = scaleDown(active: active, surplus: active.count, input: input, runtime: .tart)
            .filter(verifiable.contains)
        var released: Set<String> = []
        for id in candidates {
            released.insert(id)
            var simulated = input
            simulated.records = input.records.filter { !released.contains($0.id) }
            let remaining = active.filter { !released.contains($0.id) }
            guard remaining.count < cap else { continue }
            if let next = slots(count: 1, active: remaining, input: simulated, reserved: reserved).first,
                next.runtime != .tart
            {
                return candidates.filter(released.contains)
            }
        }
        return []
    }

    static func accountForAdmission(
        runtime: RuntimeID, containerPool namedPool: String?, records: [VMRecord],
        totals: [String: Int], input: Input
    ) -> String? {
        guard input.resources != nil else {
            return account(for: runtime, totals: totals, records: records, input: input)
        }
        guard let demand = accountDemand(runtime: runtime, containerPool: namedPool, input: input) else {
            return nil
        }
        let coverage = jobCoverage(runtime: runtime, namedPool: namedPool, records: records, input: input)
        let candidates = input.attached.intersection(
            demand.filter { account, count in
                count > (coverage[account] ?? 0)
            }.keys)
        guard !candidates.isEmpty else { return nil }
        var oldest: [String: Date] = [:]
        for candidate in candidates {
            let dates =
                namedPool.flatMap { input.containerPoolQueueDatesByAccount[candidate]?[$0] }
                ?? (namedPool == nil ? input.queueDatesByAccount[candidate]?[runtime] : nil)
            let covered = coverage[candidate] ?? 0
            if let dates, covered < dates.count { oldest[candidate] = dates[covered] }
        }
        return ForgeDemand.assignAccount(demand: demand, active: coverage, attached: candidates, oldest: oldest)
    }

    /// Jobs already covered per account, in the same units as queue counts and dates.
    static func jobCoverage(
        runtime: RuntimeID, namedPool: String?, records: [VMRecord], input: Input
    ) -> [String: Int] {
        let jobsPerInstance = max(1, input.runnersPerVM)
        var coverage: [String: Int] = [:]
        for record in records where covers(record, includesRunning: input.includesRunning) {
            guard pool(of: record, input: input) == runtime, let account = record.platform,
                namedPool == nil || containerPool(of: record, input: input) == namedPool
            else { continue }
            coverage[account, default: 0] += jobsPerInstance
        }
        return coverage
    }

    /// Demand an account can execute in this slot. Older single-account
    /// callers need no named-pool breakdown; ambiguous attribution fails closed.
    static func accountDemand(runtime: RuntimeID, containerPool: String?, input: Input) -> [String: Int]? {
        let byRuntime = input.demand.mapValues { $0[runtime] ?? 0 }
        guard runtime == .appleContainer, let containerPool else { return byRuntime }
        guard !input.containerPoolDemandByAccount.isEmpty else {
            return byRuntime.values.filter { $0 > 0 }.count <= 1 ? byRuntime : nil
        }
        let demand = input.containerPoolDemandByAccount.mapValues { $0[containerPool] ?? 0 }
        if (input.containerPoolDemand[containerPool] ?? 0) > 0, !demand.values.contains(where: { $0 > 0 }) {
            return nil
        }
        return demand
    }

}
