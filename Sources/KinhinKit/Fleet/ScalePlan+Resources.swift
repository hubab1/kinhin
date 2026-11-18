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
            // Busy Tart jobs are never preempted; the next free slot suffices.
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
    static func accountForAdmission(
        runtime chosen: RuntimeID, containerPool pool: String?, records sim: [VMRecord],
        totals: [String: Int], input: Input
    ) -> String? {
        let demand: [String: Int]
        let candidates: Set<String>
        if input.resources != nil {
            // Borrowing can pick a runtime with less total demand. Bind it to an account that can use it.
            guard let routed = accountDemand(runtime: chosen, containerPool: pool, input: input) else { return nil }
            demand = routed
            candidates = input.attached.intersection(routed.filter { $0.value > 0 }.keys)
        } else {
            demand = totals
            candidates = input.attached
        }
        guard !candidates.isEmpty else { return nil }
        var coverage: [String: Int] = [:]
        for record in sim where covers(record, includesRunning: input.includesRunning) {
            if input.resources != nil {
                guard Self.pool(of: record, input: input) == chosen,
                    pool == nil || containerPool(of: record, input: input) == pool
                else { continue }
            }
            if let account = record.platform { coverage[account, default: 0] += 1 }
        }
        return ForgeDemand.assignAccount(demand: demand, active: coverage, attached: candidates)
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
