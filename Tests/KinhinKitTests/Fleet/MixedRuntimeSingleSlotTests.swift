import XCTest

@testable import KinhinKit

/// This 16 GiB host partitions 4 CPU/8 GiB to each runtime, while admitting
/// at most ONE instance globally. The second partition is eligibility, not
/// permission to run a second job beside a busy instance.
final class MixedRuntimeSingleSlotTests: XCTestCase {
    private func input(records: [VMRecord] = [], demand: [RuntimeID: Int] = [:]) -> ScalePlan.Input {
        var value = ScalePlan.Input(
            records: records, demand: demand.isEmpty ? [:] : ["github": demand], attached: ["github"],
            maxRunners: 1, capacityCap: 2, existingPools: [.tart, .appleContainer], defaultRuntime: .tart)
        value.runnersPerVM = 1
        value.minRunners = 0
        value.poolCaps = [.tart: 1, .appleContainer: 1]
        value.warmPool = ["": 0]
        value.minIdle = [.init(runtime: .tart): 0, .init(runtime: .appleContainer): 0]
        return value
    }

    func testSimultaneousMacAndLinuxDemandStartsExactlyOneInstance() {
        let plan = ScalePlan.make(input(demand: [.tart: 3, .appleContainer: 3]))
        XCTAssertEqual(plan.slots.count, 1)
        XCTAssertEqual(plan.target, 1)
        XCTAssertTrue(plan.warmSpawn.isEmpty)
    }

    func testBusyInstanceInEitherRuntimeBlocksEveryOtherRuntimeAndAccount() {
        for runtime in [RuntimeID.tart, .appleContainer] {
            var busy = VMRecord(id: "busy", phase: .busy, createdAt: Date())
            busy.platform = "other-repo"
            busy.runtime = runtime.rawValue
            let plan = ScalePlan.make(input(records: [busy], demand: [.tart: 3, .appleContainer: 3]))
            XCTAssertTrue(plan.slots.isEmpty)
            XCTAssertEqual(plan.target, 1)
            XCTAssertTrue(plan.warmSpawn.isEmpty)
        }
    }

    func testStartingInstanceAlsoHoldsTheSingleGlobalSlot() {
        for phase in [VMPhase.cloning, .booting, .registering, .ready] {
            var incoming = VMRecord(id: "incoming", phase: phase, createdAt: Date())
            incoming.platform = "github"
            incoming.runtime = RuntimeID.appleContainer.rawValue
            let plan = ScalePlan.make(input(records: [incoming], demand: [.tart: 1]))
            XCTAssertTrue(plan.slots.isEmpty, "\(phase) already occupies the only slot")
            XCTAssertTrue(plan.warmSpawn.isEmpty)
        }
    }

    func testZeroMinAndWarmFloorsLeaveAnEmptyHostEmpty() {
        let plan = ScalePlan.make(input())
        XCTAssertTrue(plan.slots.isEmpty)
        XCTAssertEqual(plan.target, 0)
        XCTAssertTrue(plan.warmSpawn.isEmpty)
    }
}
