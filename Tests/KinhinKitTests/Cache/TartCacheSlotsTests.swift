import Foundation
import XCTest

@testable import KinhinKit

@MainActor
final class TartCacheSlotsTests: XCTestCase {
    private let first = "kinhin-1794800000-aaaa1111"
    private let second = "kinhin-1794800001-bbbb2222"
    private let third = "kinhin-1794800002-cccc3333"

    private struct Fixture {
        let root: URL
        let manager: TartCacheSlots
        let scope = "p-test"
    }

    private func withFixture(_ body: @MainActor (Fixture) async throws -> Void) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let area = temporary.resolvingSymlinksInPath()
        defer { bestEffort("test", "remove cache-slot fixture") { try FileManager.default.removeItem(at: area) } }
        let root = area.appendingPathComponent("slots")
        let scope = root.appendingPathComponent("p-test")
        for index in 0..<2 {
            let slot = scope.appendingPathComponent("slot-\(index)")
            try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
            try Data("seed".utf8).write(to: slot.appendingPathComponent("build.db"))
        }
        let manifest: [String: Any] = [
            "schema": 1, "scope": "p-test", "slots": 2,
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: scope.appendingPathComponent("manifest.json"))
        try await body(Fixture(root: root, manager: TartCacheSlots(root: root)))
    }

    private func acquire(_ vm: String, fixture: Fixture, live: Set<String> = [], started: Date = Date()) async throws
        -> [String]
    {
        try await fixture.manager.mounts(
            vm: vm, scope: fixture.scope, count: 2,
            liveVMs: live, inventoryStartedAt: started)
    }

    func testScopedTartCacheIsOptInAndSurvivesRoutingEdits() throws {
        let yaml = """
            accounts:
              - name: github
                forge: github
                scope: acme/ci
            runtimes:
              default: tart
              tart:
                isolated_cache: true
            """
        let config = try ConfigLoader.parse(yaml)
        XCTAssertEqual(RepoRoute.from(config: config, cacheMount: true, cacheScope: "p-test").cacheIsolationSlots, 2)
        XCTAssertEqual(RepoRoute.from(config: config, cacheMount: false).cacheIsolationSlots, 0)
        let runtime = try XCTUnwrap(RuntimesConfigEditor.parsed(from: yaml))
        let edited = try RuntimesConfigEditor.replaceSection(in: yaml, with: runtime)
        XCTAssertEqual(try ConfigLoader.parse(edited).runtimes?.isolatedTartCache, true)
        let defaultConfig = try ConfigLoader.parse(yaml.replacingOccurrences(of: "true", with: "false"))
        XCTAssertEqual(
            RepoRoute.from(config: defaultConfig, cacheMount: true, cacheScope: "p-test").cacheIsolationSlots, 0)
    }

    func testConcurrentVMsHaveDifferentMutableCachesAndHostOnlyLeases() async throws {
        try await withFixture { fixture in
            let a = try await acquire(first, fixture: fixture)
            let b = try await acquire(second, fixture: fixture, live: [first, second])
            XCTAssertNotEqual(a[0], b[0])
            XCTAssertEqual(a.count, 1)
            XCTAssertEqual(b.count, 1)
            let aPath = URL(fileURLWithPath: String(a[0].dropFirst("kinhin-cache:".count)))
            let bPath = URL(fileURLWithPath: String(b[0].dropFirst("kinhin-cache:".count)))
            try Data("compiler A".utf8).write(to: aPath.appendingPathComponent("build.db"))
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: aPath.deletingLastPathComponent()
                        .appendingPathComponent("lease-0/owner.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: aPath.appendingPathComponent("lease-0").path))
            XCTAssertEqual(try String(contentsOf: bPath.appendingPathComponent("build.db"), encoding: .utf8), "seed")
        }
    }

    func testStaleInventoryCannotStealAnInProcessLease() async throws {
        try await withFixture { fixture in
            _ = try await acquire(first, fixture: fixture)
            _ = try await acquire(second, fixture: fixture)
            do {
                _ = try await acquire(third, fixture: fixture, started: .distantFuture)
                XCTFail("In-process owners remain protected even when an inventory overlaps their creation")
            } catch is TartCacheSlots.Failure {}
        }
    }

    func testReleaseRequiresDeletionAndReusesProductsAfterDeletion() async throws {
        try await withFixture { fixture in
            let original = try await acquire(first, fixture: fixture)
            do {
                try await fixture.manager.releaseDeletedVM(first, liveVMs: [first])
                XCTFail("A stopped, failed or deleting VM is still present")
            } catch is TartCacheSlots.Failure {}
            try await fixture.manager.releaseDeletedVM(first, liveVMs: [])
            let next = try await acquire(second, fixture: fixture)
            XCTAssertEqual(original, next)
            let path = URL(fileURLWithPath: String(next[0].dropFirst("kinhin-cache:".count)))
            XCTAssertEqual(try String(contentsOf: path.appendingPathComponent("build.db"), encoding: .utf8), "seed")
        }
    }

    func testDeletedVMReleaseIsIdempotentAfterExternalLeaseRemoval() async throws {
        try await withFixture { fixture in
            let mounts = try await acquire(first, fixture: fixture)
            let slot = URL(fileURLWithPath: String(mounts[0].dropFirst("kinhin-cache:".count)))
            try FileManager.default.removeItem(at: slot.deletingLastPathComponent().appendingPathComponent("lease-0"))
            try await fixture.manager.releaseDeletedVM(first, liveVMs: [])
            let held = await fixture.manager.holds(first)
            XCTAssertFalse(held)
            try await fixture.manager.releaseDeletedVM(first, liveVMs: [])
        }
    }

    func testRestartReclaimsOnlyOwnersAbsentFromFreshRuntimeInventory() async throws {
        try await withFixture { fixture in
            let a = try await acquire(first, fixture: fixture)
            _ = try await acquire(second, fixture: fixture)
            let restarted = TartCacheSlots(root: fixture.root)
            let reused = try await restarted.mounts(
                vm: third, scope: fixture.scope, count: 2,
                liveVMs: [second, third], inventoryStartedAt: .distantFuture)
            XCTAssertEqual(reused, a)
        }
    }

    func testAnInventoryOlderThanAForeignClaimCannotReapThatClaim() async throws {
        try await withFixture { fixture in
            let a = try await acquire(first, fixture: fixture)
            let restarted = TartCacheSlots(root: fixture.root)
            let b = try await restarted.mounts(
                vm: second, scope: fixture.scope, count: 2,
                liveVMs: [], inventoryStartedAt: .distantPast)
            XCTAssertNotEqual(a[0], b[0])
        }
    }

    func testOwnerlessAndUnrecognisedOwnersAreNeverStolen() async throws {
        try await withFixture { fixture in
            let directory = fixture.root.appendingPathComponent(fixture.scope)
            for index in 0..<2 {
                let lease = directory.appendingPathComponent("lease-\(index)")
                try FileManager.default.createDirectory(at: lease, withIntermediateDirectories: false)
                if index == 1 {
                    try JSONSerialization.data(withJSONObject: ["vm": "external-owner", "claimedAt": 0])
                        .write(to: lease.appendingPathComponent("owner.json"))
                }
            }
            do {
                _ = try await acquire(first, fixture: fixture, started: .distantFuture)
                XCTFail("Unrecognised owners are protected without an expiry")
            } catch is TartCacheSlots.Failure {}
        }
    }

    func testSameVMRecoveryKeepsItsSlot() async throws {
        try await withFixture { fixture in
            let a = try await acquire(first, fixture: fixture)
            let b = try await acquire(first, fixture: fixture)
            XCTAssertEqual(a, b)
        }
    }

    func testSymlinkSlotIsRejectedWithoutTouchingItsTarget() async throws {
        try await withFixture { fixture in
            let directory = fixture.root.appendingPathComponent(fixture.scope)
            let slot = directory.appendingPathComponent("slot-0")
            let outside = fixture.root.appendingPathComponent("outside")
            try FileManager.default.moveItem(at: slot, to: outside)
            try FileManager.default.createSymbolicLink(at: slot, withDestinationURL: outside)
            do {
                _ = try await acquire(first, fixture: fixture)
                XCTFail("A slot must never share another path through a symlink")
            } catch is TartCacheSlots.Failure {}
            XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("build.db"), encoding: .utf8), "seed")
        }
    }
}
