import XCTest

@testable import KinhinKit

final class ScalePlanAccountCoverageTests: XCTestCase {
    private func record(_ id: String, account: String, phase: VMPhase) -> VMRecord {
        var record = VMRecord(id: id, phase: phase)
        record.platform = account
        record.runtime = RuntimeID.tart.rawValue
        return record
    }

    private func input(_ records: [VMRecord], queued: Int = 1) -> ScalePlan.Input {
        ScalePlan.Input(
            records: records, demand: ["remind": [.tart: queued]], attached: ["remind", "utter"],
            maxRunners: 2, capacityCap: 2, existingPools: [.tart], defaultRuntime: .tart)
    }

    func testReadyPeerAccountDoesNotCoverAQueuedJob() {
        let plan = ScalePlan.make(input([record("idle", account: "utter", phase: .ready)]))
        XCTAssertEqual(plan.slots.count, 1)
        XCTAssertEqual(plan.slots.first?.account, "remind")
        XCTAssertEqual(plan.unmetByPool[.tart], 1)
    }

    func testFullFleetRetiresIdleWrongAccountWithoutPreemptingBusyJob() {
        let plan = ScalePlan.make(
            input(
                [
                    record("working", account: "utter", phase: .busy),
                    record("idle", account: "utter", phase: .ready),
                ], queued: 2))
        XCTAssertTrue(plan.slots.isEmpty, "the old instance must drain before its slot is reused")
        XCTAssertEqual(plan.scaleDown, ["idle"])
        XCTAssertEqual(plan.unmetByPool[.tart], 2)
    }

    func testReadyCorrectAccountIsKeptForItsQueuedJob() {
        let plan = ScalePlan.make(
            input([
                record("working", account: "utter", phase: .busy),
                record("idle", account: "remind", phase: .ready),
            ]))
        XCTAssertTrue(plan.scaleDown.isEmpty)
        XCTAssertTrue(plan.slots.isEmpty)
    }

    func testBusyPeerAccountIsNeverRetired() {
        let plan = ScalePlan.make(
            input(
                [
                    record("one", account: "utter", phase: .busy),
                    record("two", account: "utter", phase: .busy),
                ], queued: 2))
        XCTAssertTrue(plan.scaleDown.isEmpty)
    }

    func testMinimumFleetFloorStillHoldsDuringRebalancing() {
        var value = input(
            [
                record("working", account: "utter", phase: .busy),
                record("idle", account: "utter", phase: .ready),
            ], queued: 2)
        value.minRunners = 2
        XCTAssertTrue(ScalePlan.make(value).scaleDown.isEmpty)
    }

    func testReadyPeerCannotStealRequiredImageFromNewRunner() {
        var peer = record("idle", account: "utter", phase: .ready)
        peer.image = "xcode-private-cache"
        var value = input([peer])
        value.imageDemand = ["xcode-private-cache": 1]
        value.imageDemandByAccount = ["remind": ["xcode-private-cache": 1], "utter": [:]]
        let plan = ScalePlan.make(value)
        XCTAssertEqual(plan.slots.first?.account, "remind")
        XCTAssertEqual(plan.slots.first?.image, "xcode-private-cache")
    }

    func testEachAccountGetsItsOwnQueuedImage() {
        var value = input([])
        value.demand = ["remind": [.tart: 1], "utter": [.tart: 1]]
        value.imageDemand = ["remind-image": 1, "utter-image": 1]
        value.imageDemandByAccount = ["remind": ["remind-image": 1], "utter": ["utter-image": 1]]
        let plan = ScalePlan.make(value)
        XCTAssertEqual(plan.slots.first { $0.account == "remind" }?.image, "remind-image")
        XCTAssertEqual(plan.slots.first { $0.account == "utter" }?.image, "utter-image")
    }
}
