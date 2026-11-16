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
        var input = input(records: [record("busy-mac")], linux: 1)
        input.containerPools = [
            "large": .init(cpus: 2, memoryGB: 8, max: 1),
            "small": .init(cpus: 1, memoryGB: 2, max: 1),
        ]
        input.defaultContainerPool = "small"
        input.containerPoolDemand = ["large": 1]
        input.containerPoolDemandByAccount = ["github": ["large": 1]]
        input.containerBudget = .init(cpu: 8, memoryGB: 12)
        XCTAssertTrue(ScalePlan.make(input).slots.isEmpty, "Eight GiB do not fit beside a six GiB Mac")
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
