import Darwin
import Foundation

/// Persistent single-writer cache slots. Every Tart runtime uses `shared`, so
/// an inventory read that overlaps another acquisition cannot reap its lease.
actor TartCacheSlots {
    static let shared = TartCacheSlots()

    private struct Manifest: Codable {
        let schema: Int
        let scope: String
        let slots: Int
    }

    private struct Owner: Codable {
        let vm: String
        let claimedAt: Date
    }

    private let root: URL?
    private var held: [String: URL] = [:]

    init(root: URL? = nil) { self.root = root }

    func mounts(vm: String, scope: String, count: Int, liveVMs: Set<String>, inventoryStartedAt: Date)
        throws -> [String]
    {
        // Teardown cancels provisioning before it inspects the lease. An
        // acquisition queued behind that inspection must never claim a slot.
        try Task.checkCancellation()
        guard validVM(vm), validComponent(scope), count == 2 else {
            throw TartError.isolatedCache("Invalid isolated runner cache identity or slot count")
        }
        let cache = Paths.toolchainCache
        let slotsRoot =
            root
            ?? cache.deletingLastPathComponent()
            .appendingPathComponent(".\(cache.lastPathComponent)-tart-slots")
        let directory = slotsRoot.appendingPathComponent(scope)
        try requireUnlinked(directory)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try requireUnlinked(manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.schema == 1, manifest.scope == scope, manifest.slots == count else {
            throw TartError.isolatedCache("Cache slots must be prepared offline for this project image")
        }
        // Check every slot for this VM before taking a free one, so a recovered
        // stopped VM keeps its original products even if an earlier slot is free.
        var available: (slot: URL, lease: URL, reclaim: Bool)?
        for index in 0..<count {
            let slot = directory.appendingPathComponent("slot-\(index)")
            try requireUnlinked(slot)
            guard FileManager.default.fileExists(atPath: slot.path) else {
                throw TartError.isolatedCache("Prepared cache slot is missing: \(slot.path)")
            }
            let lease = directory.appendingPathComponent("lease-\(index)")
            try requireUnlinked(lease)
            let leased = FileManager.default.fileExists(atPath: lease.path)
            if leased {
                let ownerURL = lease.appendingPathComponent("owner.json")
                try requireUnlinked(ownerURL)
                // Protect an incomplete legacy lease. New leases are published
                // with an owner in a single rename.
                guard FileManager.default.fileExists(atPath: ownerURL.path) else { continue }
                let owner = try JSONDecoder().decode(Owner.self, from: Data(contentsOf: ownerURL))
                if owner.vm == vm {
                    held[vm] = lease
                    return [ToolchainCacheMount.guestDirectoryName + ":" + slot.path]
                }
                guard validVM(owner.vm), held[owner.vm] == nil, !liveVMs.contains(owner.vm),
                    owner.claimedAt < inventoryStartedAt
                else { continue }
            }
            if available == nil { available = (slot, lease, leased) }
        }
        guard let available else {
            throw TartError.isolatedCache(
                "All isolated cache slots are leased; live or unknown owners remain protected")
        }
        if available.reclaim { try FileManager.default.removeItem(at: available.lease) }
        try publishLease(at: available.lease, owner: Owner(vm: vm, claimedAt: Date()))
        held[vm] = available.lease
        return [ToolchainCacheMount.guestDirectoryName + ":" + available.slot.path]
    }

    private func publishLease(at lease: URL, owner: Owner) throws {
        let stage = lease.deletingLastPathComponent().appendingPathComponent(".claim-\(UUID().uuidString)")
        let manager = FileManager.default
        try manager.createDirectory(at: stage, withIntermediateDirectories: false)
        defer {
            if manager.fileExists(atPath: stage.path) {
                bestEffort("cache", "remove unpublished cache lease") { try manager.removeItem(at: stage) }
            }
        }
        try JSONEncoder().encode(owner).write(to: stage.appendingPathComponent("owner.json"))
        // Rename on the same filesystem publishes the directory and owner together.
        // Exclusive rename also protects against an unexpected concurrent claim.
        guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, lease.path, UInt32(RENAME_EXCL)) == 0 else {
            throw TartError.isolatedCache("Could not publish isolated cache lease (errno \(errno))")
        }
    }

    func holds(_ vm: String) -> Bool { held[vm] != nil }

    /// The caller must prove deletion using the runtime's actual inventory.
    func releaseDeletedVM(_ vm: String, liveVMs: Set<String>) throws {
        guard !liveVMs.contains(vm) else {
            throw TartError.isolatedCache("Cannot release the cache of a VM that still exists")
        }
        guard let lease = held[vm] else { return }
        try requireUnlinked(lease)
        if !FileManager.default.fileExists(atPath: lease.path) {
            held.removeValue(forKey: vm)
            return
        }
        let ownerURL = lease.appendingPathComponent("owner.json")
        try requireUnlinked(ownerURL)
        let owner = try JSONDecoder().decode(Owner.self, from: Data(contentsOf: ownerURL))
        guard owner.vm == vm else { throw TartError.isolatedCache("Runner cache lease ownership changed") }
        try FileManager.default.removeItem(at: lease)
        held.removeValue(forKey: vm)
    }

    private func requireUnlinked(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"),
            url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL
        else { throw TartError.isolatedCache("Runner cache paths must not traverse symlinks") }
    }

    private func validComponent(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil
    }

    private func validVM(_ value: String) -> Bool {
        value.range(of: InstanceNaming.generatedNamePattern, options: .regularExpression) != nil
    }
}
