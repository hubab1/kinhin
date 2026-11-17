import XCTest

@testable import KinhinKit

final class ScalePlanQueuedImageTests: XCTestCase {
    private func plan(busyAccount: String, includesRunning: Bool = false) -> ScalePlan {
        var busy = VMRecord(id: "kinhin-busy", phase: .busy)
        busy.platform = busyAccount
        busy.runtime = RuntimeID.tart.rawValue
        busy.image = "xcode-with-private-cache"
        var input = ScalePlan.Input(
            records: [busy], demand: ["utter": [.tart: includesRunning ? 2 : 1]],
            attached: ["remind", "utter"], maxRunners: 2, capacityCap: 2,
            existingPools: [.tart], defaultRuntime: .tart)
        input.imageDemand = ["xcode-with-private-cache": includesRunning ? 2 : 1]
        if includesRunning { input.includesRunning = [busyAccount] }
        return ScalePlan.make(input)
    }

    func testBusyPeerCannotReplaceQueuedJobsRequiredImageWithBase() {
        let result = plan(busyAccount: "remind")
        XCTAssertEqual(result.slots.count, 1)
        XCTAssertEqual(result.slots.first?.account, "utter")
        XCTAssertEqual(result.slots.first?.image, "xcode-with-private-cache")
    }

    func testBusySameAccountDoesNotCoverQueuedImageWithWarmPoolsOff() {
        let result = plan(busyAccount: "utter")
        XCTAssertEqual(result.slots.count, 1)
        XCTAssertEqual(result.slots.first?.image, "xcode-with-private-cache")
    }

    func testScaleSetImageStillCountsItsRunningJob() {
        let result = plan(busyAccount: "utter", includesRunning: true)
        XCTAssertEqual(result.slots.count, 1)
        XCTAssertEqual(result.slots.first?.image, "xcode-with-private-cache")
    }
}
