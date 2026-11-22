import XCTest

@testable import KinhinKit

final class ScalePlanResourceBudgetTests: XCTestCase {
    private func record(
        _ id: String, runtime: RuntimeID = .tart, phase: VMPhase = .busy,
        cpu: Int = 4, memory: Int = 6
    ) -> VMRecord {
        var record = VMRecord(id: id, phase: phase)
        record.platform = "github"
        record.runtimeID = runtime
        record.resourceReservation = VMResourceReservation(cpu: cpu, memoryGB: memory)
        return record
    }

    private func input(records: [VMRecord] = [], mac: Int = 0, linux: Int = 0) -> ScalePlan.Input {
        var input = ScalePlan.Input(
            records: records, demand: ["github": [.tart: mac, .appleContainer: linux]],
            attached: ["github"], maxRunners: 4, capacityCap: 4,
            poolCaps: [.tart: 2, .appleContainer: 1], existingPools: [.tart, .appleContainer],
            defaultRuntime: .tart)
        input.resources = ScaleResourceBudget(
            capacity: VMResourceReservation(cpu: 8, memoryGB: 12),
            shapes: [
                .tart: VMResourceReservation(cpu: 4, memoryGB: 6),
                .appleContainer: VMResourceReservation(cpu: 2, memoryGB: 4),
            ])
        return input
    }

    func testTwoSixGiBMacsFitWhenLinuxIsIdle() {
        let plan = ScalePlan.make(input(mac: 10))
        XCTAssertEqual(plan.slots.map(\.runtime), [.tart, .tart])
        XCTAssertTrue(plan.warmSpawn.isEmpty)
    }

    func testBusyLinuxReservationLeavesRoomForOnlyOneMac() {
        let linux = record("linux", runtime: .appleContainer, cpu: 2, memory: 4)
        let plan = ScalePlan.make(input(records: [linux], mac: 10))
        XCTAssertEqual(plan.slots.map(\.runtime), [.tart])
        XCTAssertTrue(plan.scaleDown.isEmpty, "Never preempt a busy Linux job to borrow its share")
    }

    func testTwoBusyMacsHoldLinuxUntilOneActuallyExits() {
        let macs = [record("mac-a"), record("mac-b")]
        XCTAssertTrue(ScalePlan.make(input(records: macs, linux: 1)).slots.isEmpty)
        XCTAssertEqual(ScalePlan.make(input(records: [macs[0]], linux: 1)).slots.map(\.runtime), [.appleContainer])
    }

    func testLinuxGetsItsShareBackAtTheNextFreeSlotDespiteMoreMacDemand() {
        let plan = ScalePlan.make(input(records: [record("busy-mac")], mac: 100, linux: 1))
        XCTAssertEqual(plan.slots.map(\.runtime), [.appleContainer])
        XCTAssertTrue(plan.scaleDown.isEmpty)
    }

    func testLargerLinuxJobKeepsTheNextSlotOpenUntilTartDrains() {
        var input = input(records: [record("busy-mac")], mac: 100, linux: 1)
        input.maxRunners = 2
        input.resources?.shapes[.appleContainer] = VMResourceReservation(cpu: 2, memoryGB: 8)
        let draining = ScalePlan.make(input)
        XCTAssertTrue(draining.slots.isEmpty)
        XCTAssertTrue(draining.scaleDown.isEmpty)
        input.records = []
        XCTAssertEqual(ScalePlan.make(input).slots.map(\.runtime), [.appleContainer])
    }

    func testLinuxJobTooLargeForTheHostDoesNotBlockTartIndefinitely() {
        var input = input(records: [record("busy-mac")], mac: 100, linux: 1)
        input.maxRunners = 2
        input.resources?.shapes[.appleContainer] = VMResourceReservation(cpu: 2, memoryGB: 13)
        XCTAssertEqual(ScalePlan.make(input).slots.map(\.runtime), [.tart])
    }

    func testReadyTartWithoutWaitingWorkCanReturnItsSlot() {
        var input = input(records: [record("idle-mac", phase: .ready), record("busy-mac")], linux: 2)
        input.maxRunners = 2
        let plan = ScalePlan.make(input)
        XCTAssertTrue(plan.slots.isEmpty)
        XCTAssertEqual(plan.scaleDown, ["idle-mac"])
        input.records.removeFirst()
        XCTAssertEqual(ScalePlan.make(input).slots.map(\.runtime), [.appleContainer])
    }

    func testReadyTartNeededForMacQueueStaysUp() {
        var input = input(records: [record("idle-mac", phase: .ready), record("busy-mac")], mac: 1, linux: 2)
        input.maxRunners = 2
        XCTAssertTrue(ScalePlan.make(input).scaleDown.isEmpty)
    }

    func testLargerLinuxReleasesOnlyTheIdleVMsItNeedsAfterMacWorkIsCancelled() {
        var input = input(records: [record("idle-a", phase: .ready), record("idle-b", phase: .ready)], linux: 2)
        input.maxRunners = 2
        input.resources?.shapes[.appleContainer] = VMResourceReservation(cpu: 2, memoryGB: 8)
        XCTAssertEqual(Set(ScalePlan.make(input).scaleDown), ["idle-a", "idle-b"])
        input.heldRuntimes.insert(.appleContainer)
        XCTAssertTrue(ScalePlan.make(input).scaleDown.isEmpty)
    }

    func testMultiRunnerLinuxCoverageBelongsToTheAccountItCanServe() {
        var linux = record("existing", runtime: .appleContainer, phase: .ready, cpu: 2, memory: 4)
        linux.pool = "tests"
        var input = input(records: [linux], linux: 3)
        input.maxRunners = 2
        input.runnersPerVM = 3
        input.attached.insert("waiting")
        input.demand["waiting"] = [.appleContainer: 1]
        input.poolCaps[.appleContainer] = 2
        input.containerPools = ["tests": .init(cpus: 2, memoryGB: 4, max: 2)]
        input.defaultContainerPool = "tests"
        input.containerPoolDemand = ["tests": 4]
        input.containerPoolDemandByAccount = ["github": ["tests": 3], "waiting": ["tests": 1]]
        let slots = ScalePlan.make(input).slots
        XCTAssertEqual(slots.map(\.pool), ["tests"])
        XCTAssertEqual(slots.map(\.account), ["waiting"])
    }

    func testLinuxCoverageCannotHideAnotherAccountsSingleWaitingJob() {
        let linux = record("existing", runtime: .appleContainer, phase: .ready, cpu: 2, memory: 4)
        var input = input(records: [linux])
        input.maxRunners = 2
        input.attached.insert("waiting")
        input.demand["waiting"] = [.appleContainer: 1]
        input.poolCaps[.appleContainer] = 2
        input.containerPools = ["tests": .init(cpus: 2, memoryGB: 4, max: 2)]
        input.defaultContainerPool = "tests"
        input.containerPoolDemand = ["tests": 1]
        input.containerPoolDemandByAccount = ["waiting": ["tests": 1]]
        let slots = ScalePlan.make(input).slots
        XCTAssertEqual(slots.map(\.pool), ["tests"])
        XCTAssertEqual(slots.map(\.account), ["waiting"])
    }

    func testBorrowingUsesQueueDatesForAccountsInTheSelectedLinuxPool() {
        var input = input(linux: 10)
        input.maxRunners = 1
        input.attached.insert("older")
        input.demand["older"] = [.appleContainer: 2]
        input.containerPools = ["tests": .init(cpus: 2, memoryGB: 4, max: 1)]
        input.defaultContainerPool = "tests"
        input.containerPoolDemand = ["tests": 11]
        input.containerPoolDemandByAccount = ["github": ["tests": 10], "older": ["tests": 1]]
        input.containerPoolQueueDatesByAccount = [
            "github": ["tests": [Date(timeIntervalSince1970: 200)]],
            "older": ["tests": [Date(timeIntervalSince1970: 100)]],
        ]
        XCTAssertEqual(ScalePlan.make(input).slots.map(\.account), ["older"])
    }

    func testBorrowingBindsPrioritizedLinuxToItsOwnAccount() {
        var input = input(records: [record("busy-mac")], mac: 50)
        input.attached.insert("linux-repo")
        input.demand["linux-repo"] = [.appleContainer: 1]
        let slots = ScalePlan.make(input).slots
        XCTAssertEqual(slots.map(\.runtime), [.appleContainer])
        XCTAssertEqual(slots.map(\.account), ["linux-repo"])
    }

    func testReloadCannotPretendAnEightGiBVMAlreadyUsesSixGiB() {
        let older = record("existing-eight-gib", memory: 8)
        XCTAssertTrue(ScalePlan.make(input(records: [older], mac: 2)).slots.isEmpty)
        XCTAssertEqual(ScalePlan.make(input(records: [older], linux: 1)).slots.map(\.runtime), [.appleContainer])
    }

    func testUnknownLegacyOrAdoptedAllocationHoldsTheEntireBudget() {
        var legacy = record("legacy")
        legacy.resourceReservation = nil
        XCTAssertTrue(ScalePlan.make(input(records: [legacy], mac: 10, linux: 1)).slots.isEmpty)
        legacy.resourceReservation = VMResourceReservation(cpu: 0, memoryGB: -1)
        XCTAssertTrue(ScalePlan.make(input(records: [legacy], mac: 10, linux: 1)).slots.isEmpty)
    }

    func testDeletingAndFailedInstancesStayChargedUntilTheirRecordsAreRemoved() {
        for phase in [VMPhase.deleting, .failed] {
            let retained = record("not-yet-gone", phase: phase)
            XCTAssertEqual(ScalePlan.make(input(records: [retained], mac: 10)).slots.count, 1)
        }
        XCTAssertEqual(ScalePlan.make(input(mac: 10)).slots.count, 2)
    }

    func testNamedLinuxPoolsAreChargedTheirActualShapeRatherThanTheMinimumShape() {
        var input = input(records: [record("busy-mac")], mac: 100, linux: 1)
        input.containerPools = [
            "large": .init(cpus: 2, memoryGB: 8, max: 1),
            "small": .init(cpus: 1, memoryGB: 2, max: 1),
        ]
        input.defaultContainerPool = "small"
        input.containerPoolDemand = ["large": 1]
        input.containerPoolDemandByAccount = ["github": ["large": 1]]
        input.containerBudget = .init(cpu: 8, memoryGB: 12)
        XCTAssertTrue(ScalePlan.make(input).slots.isEmpty, "Eight GiB do not fit beside a six GiB Mac")
        input.records = []
        XCTAssertEqual(ScalePlan.make(input).slots.first?.pool, "large")
    }

    func testFixedPartitionModeKeepsItsOriginalCountCap() {
        var input = input(mac: 10)
        input.resources = nil
        input.poolCaps[.tart] = 1
        XCTAssertEqual(ScalePlan.make(input).slots.count, 1)
    }

    func testPersistedAllocationSurvivesAStateRoundTrip() throws {
        let original = record("kinhin-1794851987-920863ac", cpu: 6, memory: 8)
        let decoded = try JSONDecoder().decode(VMRecord.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.resourceReservation, original.resourceReservation)
    }
}
