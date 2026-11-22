import Foundation

extension TartRuntime {
    func cacheMounts(id: String, route: RepoRoute, leases: TartCacheSlots = .shared) async throws -> [String] {
        guard route.cacheMount else { return [] }
        guard route.cacheIsolationSlots > 0 else {
            return [ToolchainCacheMount.tartDirectorySpec(scope: route.cacheScope)]
        }
        guard let scope = route.cacheScope else {
            throw TartError.isolatedCache("Isolated caches require a project image scope")
        }
        try StoragePreflight.live.requireReady(.toolchainCache)
        let inventoryStartedAt = Date()
        let inventory = try await tart.list()
        return try await leases.mounts(
            vm: id, scope: scope, count: route.cacheIsolationSlots,
            liveVMs: Set(inventory.map(\.name)),
            inventoryStartedAt: inventoryStartedAt)
    }

    func releaseCacheSlot(id: String) async throws {
        guard await TartCacheSlots.shared.holds(id) else { return }
        let inventory = try await tart.list()
        try await TartCacheSlots.shared.releaseDeletedVM(id, liveVMs: Set(inventory.map(\.name)))
    }
}
