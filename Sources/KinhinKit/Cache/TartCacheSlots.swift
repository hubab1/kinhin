import Foundation

/// Persistent single-writer cache slots. Every Tart runtime uses `shared`, so
/// an inventory read that overlaps another acquisition cannot reap its lease.
actor TartCacheSlots {
    static let shared = TartCacheSlots()

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

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
        guard validVM(vm), validComponent(scope), count == 2 else {
            throw Failure(message: "Invalid isolated runner cache identity or slot count")
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
            throw Failure(message: "Cache slots must be prepared offline for this project image")
        }
        for index in 0..<count {
            let slot = directory.appendingPathComponent("slot-\(index)")
            try requireUnlinked(slot)
            guard FileManager.default.fileExists(atPath: slot.path) else {
                throw Failure(message: "Prepared cache slot is missing: \(slot.path)")
            }
            let lease = directory.appendingPathComponent("lease-\(index)")
            try requireUnlinked(lease)
            if FileManager.default.fileExists(atPath: lease.path) {
                let ownerURL = lease.appendingPathComponent("owner.json")
                try requireUnlinked(ownerURL)
                // An ownerless lease is never stolen. Offline preparation can
                // reclaim it only after all runner guests have been deleted.
                guard FileManager.default.fileExists(atPath: ownerURL.path) else { continue }
                let owner = try JSONDecoder().decode(Owner.self, from: Data(contentsOf: ownerURL))
                if owner.vm == vm {
                    held[vm] = lease
                    return [ToolchainCacheMount.guestDirectoryName + ":" + slot.path]
                }
                guard validVM(owner.vm), held[owner.vm] == nil, !liveVMs.contains(owner.vm),
                    owner.claimedAt < inventoryStartedAt
                else { continue }
                try FileManager.default.removeItem(at: lease)
            }
            do {
                try FileManager.default.createDirectory(at: lease, withIntermediateDirectories: false)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
            try JSONEncoder().encode(Owner(vm: vm, claimedAt: Date())).write(
                to: lease.appendingPathComponent("owner.json"), options: .atomic)
            held[vm] = lease
            return [ToolchainCacheMount.guestDirectoryName + ":" + slot.path]
        }
        throw Failure(message: "All isolated cache slots are leased; live or unknown owners remain protected")
    }

    func holds(_ vm: String) -> Bool { held[vm] != nil }

    /// The caller must prove deletion using the runtime's actual inventory.
    func releaseDeletedVM(_ vm: String, liveVMs: Set<String>) throws {
        guard !liveVMs.contains(vm) else {
            throw Failure(message: "Cannot release the cache of a VM that still exists")
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
        guard owner.vm == vm else { throw Failure(message: "Runner cache lease ownership changed") }
        try FileManager.default.removeItem(at: lease)
        held.removeValue(forKey: vm)
    }

    private func requireUnlinked(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"),
            url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL
        else { throw Failure(message: "Runner cache paths must not traverse symlinks") }
    }

    private func validComponent(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil
    }

    private func validVM(_ value: String) -> Bool {
        value.range(of: "^kinhin-[0-9]{9,11}-[0-9a-f]{4,8}$", options: .regularExpression) != nil
    }
}
