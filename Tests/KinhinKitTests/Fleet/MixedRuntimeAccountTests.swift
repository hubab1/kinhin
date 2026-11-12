import XCTest

@testable import KinhinKit

final class MixedRuntimeAccountTests: XCTestCase {
    private func input(demand: [String: [RuntimeID: Int]], records: [VMRecord] = []) -> ScalePlan.Input {
        var value = ScalePlan.Input(
            records: records, demand: demand, attached: Set(demand.keys),
            maxRunners: 1, capacityCap: 2, existingPools: [.tart, .appleContainer], defaultRuntime: .tart)
        value.poolCaps = [.tart: 1, .appleContainer: 1]
        value.containerPools = ["supportedhome": .init(cpus: 4, memoryGB: 8, max: 1)]
        value.defaultContainerPool = "supportedhome"
        value.containerBudget = RuntimeCapacity.Budget(cpu: 4, memoryGB: 8)
        value.containerPoolDemand = ["supportedhome": demand.values.reduce(0) { $0 + ($1[.appleContainer] ?? 0) }]
        value.containerPoolDemandByAccount = demand.mapValues { ["supportedhome": $0[.appleContainer] ?? 0] }
        return value
    }

    func testSingleSlotBindsLinuxToTheAccountWithLinuxJobs() throws {
        let value = input(demand: ["utter-ci": [.tart: 2], "supportedhome-ci": [.appleContainer: 1]])
        let plan = ScalePlan.make(value)
        XCTAssertEqual(plan.slots.count, 1)
        let slot = try XCTUnwrap(plan.slots.first)
        XCTAssertEqual(slot.runtime, .appleContainer, "retain the existing capped runtime tie-break")
        XCTAssertEqual(slot.pool, "supportedhome")
        XCTAssertEqual(slot.account, "supportedhome-ci", "Utter's macOS queue cannot use this Linux runner")
        XCTAssertGreaterThan(value.demand[slot.account]?[slot.runtime] ?? 0, 0)
    }

    func testHeldLinuxPoolDoesNotAssignItsAccountToTheMacSlot() {
        var value = input(demand: ["utter-ci": [.tart: 1], "supportedhome-ci": [.appleContainer: 3]])
        value.heldRuntimes = [.appleContainer]
        let plan = ScalePlan.make(value)
        XCTAssertEqual(plan.slots.map(\.runtime), [.tart])
        XCTAssertEqual(plan.slots.map(\.account), ["utter-ci"])
    }

    func testExhaustedRuntimeCapDoesNotStealTheOtherAccountsSlot() {
        var value = input(demand: ["utter-ci": [.tart: 1], "supportedhome-ci": [.appleContainer: 3]])
        value.poolCaps[.appleContainer] = 0
        let plan = ScalePlan.make(value)
        XCTAssertEqual(plan.slots.map(\.runtime), [.tart])
        XCTAssertEqual(plan.slots.map(\.account), ["utter-ci"])
    }

    func testNamedPoolAndAccountAreSelectedFromTheSameDemand() throws {
        var value = input(demand: ["a": [.appleContainer: 3], "b": [.appleContainer: 4], "c": [.appleContainer: 3]])
        value.containerPools = [
            "one": .init(cpus: 4, memoryGB: 8, max: 1), "two": .init(cpus: 4, memoryGB: 8, max: 1),
        ]
        value.defaultContainerPool = "one"
        value.containerPoolDemand = ["one": 6, "two": 4]
        value.containerPoolDemandByAccount = ["a": ["one": 3], "b": ["two": 4], "c": ["one": 3]]
        let slot = try XCTUnwrap(ScalePlan.make(value).slots.first)
        XCTAssertEqual(slot.pool, "one")
        XCTAssertEqual(slot.account, "a", "account b cannot use pool one despite its larger total queue")
        XCTAssertGreaterThan(value.containerPoolDemandByAccount[slot.account]?[slot.pool ?? ""] ?? 0, 0)
    }

    func testExhaustedNamedPoolDoesNotAssignItsAccountToAnotherPool() throws {
        var value = input(demand: ["a": [.appleContainer: 1], "b": [.appleContainer: 3]])
        value.containerPools = [
            "one": .init(cpus: 4, memoryGB: 8, max: 1), "two": .init(cpus: 4, memoryGB: 8, max: 0),
        ]
        value.defaultContainerPool = "one"
        value.containerPoolDemand = ["one": 1, "two": 3]
        value.containerPoolDemandByAccount = ["a": ["one": 1], "b": ["two": 3]]
        let slot = try XCTUnwrap(ScalePlan.make(value).slots.first)
        XCTAssertEqual(slot.pool, "one")
        XCTAssertEqual(slot.account, "a")
    }

    func testAmbiguousNamedPoolAttributionStartsNoIncompatibleRunner() {
        var value = input(demand: ["a": [.appleContainer: 1], "b": [.appleContainer: 3]])
        value.containerPoolDemandByAccount = [:]
        XCTAssertTrue(ScalePlan.make(value).slots.isEmpty)
    }

    func testAccountFairnessCountsOnlyCoverageWithinTheSelectedRuntime() throws {
        var ready = VMRecord(id: "existing-mac", phase: .ready)
        ready.platform = "utter-ci"
        ready.runtimeID = .tart
        var value = input(
            demand: ["utter-ci": [.tart: 2, .appleContainer: 1], "supportedhome-ci": [.appleContainer: 1]],
            records: [ready])
        value.maxRunners = 2
        value.capacityCap = 3
        value.poolCaps[.tart] = 2
        let slot = try XCTUnwrap(ScalePlan.make(value).slots.first)
        XCTAssertEqual(slot.runtime, .appleContainer)
        XCTAssertEqual(slot.account, "supportedhome-ci", "equal Linux demand keeps the account name tie-break")
    }

    func testEveryPlannedRuntimeHasDemandInItsSelectedAccount() {
        var value = input(
            demand: ["utter-ci": [.tart: 4], "supportedhome-ci": [.appleContainer: 1], "other-mac": [.tart: 1]])
        value.maxRunners = 3
        value.capacityCap = 3
        value.poolCaps[.tart] = 2
        let plan = ScalePlan.make(value)
        XCTAssertEqual(plan.slots.count, 3)
        XCTAssertEqual(plan.slots.filter { $0.runtime == .appleContainer }.count, 1)
        XCTAssertEqual(plan.slots.filter { $0.runtime == .tart }.count, 2)
        for slot in plan.slots {
            XCTAssertGreaterThan(value.demand[slot.account]?[slot.runtime] ?? 0, 0)
        }
    }

    func testNoQueueMinimumKeepsTheLegacyAccountAndDefaultRuntime() {
        var value = input(demand: [:])
        value.attached = ["github", "other"]
        value.minRunners = 1
        let plan = ScalePlan.make(value)
        XCTAssertEqual(plan.slots.map(\.account), ["github"])
        XCTAssertEqual(plan.slots.map(\.runtime), [.tart])
    }
}
