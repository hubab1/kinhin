import XCTest

@testable import KinhinKit

final class RuntimeIdleBorrowingTests: XCTestCase {
    private let yaml = """
        version: 1
        min_runners: 0
        max_runners: 2
        warm_pool: 0
        image_min_idle: 0
        vm: {cpu: 4, memory_gb: 6}
        reserve: {cpu: 0, memory_gb: 4, disk_gb: 20}
        container: {image: linux-ci, cpus: 2, memory_gb: 4}
        runtimes:
          default: tart
          budget: {appleContainer: 0.3333333333333334}
          borrow_idle_budget: true
        """

    func testDefaultPoolCanBorrowButLinuxKeepsItsOriginalCountCap() throws {
        let config = try ConfigLoader.parse(yaml)
        let host = HostResources(logicalCores: 8, memoryGB: 16, freeDiskGB: 200, arm64: true)
        let caps = RuntimeCapacity.caps(for: config, host: host)
        XCTAssertEqual(caps[.tart], 2)
        XCTAssertEqual(caps[.appleContainer], 1)
        var fixed = config
        fixed.runtimes?.borrowIdleBudget = false
        XCTAssertEqual(RuntimeCapacity.caps(for: fixed, host: host)[.tart], 1)
    }

    func testDisabledTartPoolIsNotResurrectedByBorrowing() throws {
        var config = try ConfigLoader.parse(yaml)
        config.runtimes?.tartEnabled = false
        let host = HostResources(logicalCores: 8, memoryGB: 16, freeDiskGB: 200, arm64: true)
        var fixed = config
        fixed.runtimes?.borrowIdleBudget = false
        XCTAssertEqual(RuntimeCapacity.caps(for: config, host: host), RuntimeCapacity.caps(for: fixed, host: host))
        XCTAssertNil(RuntimeConfigModel(config: config).pools[.tart])
        let section = RuntimesConfigEditor.sectionText(try XCTUnwrap(config.runtimes))
        let parsed = try XCTUnwrap(RuntimesConfigEditor.parsed(from: section))
        XCTAssertFalse(parsed.tartEnabled)
        XCTAssertTrue(parsed.borrowIdleBudget)
    }

    func testOmittingTheFlagPreservesFixedPartitioning() throws {
        let config = try ConfigLoader.parse(yaml.replacingOccurrences(of: "  borrow_idle_budget: true", with: ""))
        XCTAssertEqual(config.runtimes?.borrowIdleBudget, false)
    }

    func testWarmAndIdleFloorsAreRejectedInsteadOfSilentlyOversubscribing() {
        for (old, replacement) in [
            ("warm_pool: 0", "warm_pool: 1"),
            ("image_min_idle: 0", "image_min_idle: 1"),
            ("min_runners: 0", "min_runners: 1"),
            ("cpus: 2, memory_gb: 4}", "cpus: 2, memory_gb: 4, min_idle: 1}"),
        ] {
            XCTAssertThrowsError(try ConfigLoader.parse(yaml.replacingOccurrences(of: old, with: replacement)))
        }
    }

    func testPersistentVMsAreRejectedInBorrowingMode() {
        let persistent = yaml.replacingOccurrences(of: "memory_gb: 6}", with: "memory_gb: 6, ephemeral: false}")
        XCTAssertThrowsError(try ConfigLoader.parse(persistent)) { error in
            XCTAssertTrue(error.localizedDescription.contains("vm.ephemeral: true"))
        }
    }

    func testEditingRoutesPreservesBorrowingAndTheLinuxBudget() throws {
        var model = try XCTUnwrap(RuntimesConfigEditor.parsed(from: yaml))
        XCTAssertTrue(model.borrowIdleBudget)
        model.routes.append(.init(pattern: "example/repo", runtime: .appleContainer))
        let section = RuntimesConfigEditor.sectionText(model)
        let edited = try ConfigLoader.parse(
            String(yaml.prefix(upTo: try XCTUnwrap(yaml.range(of: "runtimes:")).lowerBound)) + section)
        XCTAssertTrue(try XCTUnwrap(edited.runtimes).borrowIdleBudget)
        XCTAssertEqual(edited.runtimes?.budget["appleContainer"], model.budget["appleContainer"])
    }

    func testChangingBorrowingRequiresRebuildingTheEngine() throws {
        let on = try ConfigLoader.parse(yaml)
        var off = on
        off.runtimes?.borrowIdleBudget = false
        XCTAssertTrue(FleetEngine.restartRequired(from: off, to: on))
    }
}
