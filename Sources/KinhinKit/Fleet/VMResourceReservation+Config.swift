import Foundation

extension VMResourceReservation {
    static func configured(
        for runtime: RuntimeID, in config: KinhinConfig, containerPool: String? = nil
    ) -> VMResourceReservation? {
        if runtime == .appleContainer, let container = config.container, !container.pools.isEmpty {
            let name = containerPool ?? container.defaultPool.name
            guard let pool = container.pools.first(where: { $0.name == name }) else { return nil }
            return VMResourceReservation(cpu: pool.cpus, memoryGB: pool.memoryGB)
        }
        let shape = RuntimeCapacity.shape(of: runtime, in: config)
        return VMResourceReservation(cpu: shape.cpu, memoryGB: shape.memoryGB)
    }
}
