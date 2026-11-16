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
}
