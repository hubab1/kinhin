import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class ScaleDownSafetyTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    func testRejectedRunnerRetirementNeverStopsVMOrCancelsItsWatcher() async throws {
        let deletes = Locked(0)
        StubProtocol.handler = { request in
            if request.httpMethod == "DELETE" {
                deletes.withLock { $0 += 1 }
                return (422, Data(#"{"message":"Runner is currently running a job and cannot be deleted."}"#.utf8), [:])
            }
            return (
                200,
                Data(
                    #"{"total_count":1,"runners":[{"id":7,"name":"kinhin-retire","status":"online","busy":false,"labels":[]}]}"#
                        .utf8), [:]
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let client = GitHubClient(
            credentials: GitHubCredentials(token: "test-token", scope: "acme/widgets"),
            session: URLSession(configuration: configuration))
        let tart = FakeTart()
        let engine = FleetEngine(
            config: makeTestConfig(), github: FakeGitHub(), tart: tart,
            store: makeTestStore(), ssh: FakeSSH(), host: testHost)
        engine.forgeState.withLock {
            $0.byPlatform["github"] = GitHubForge(
                credentials: .github(token: "test-token", scope: "acme/widgets"),
                labels: ["kinhin"], client: client)
        }
        var record = VMRecord(id: "kinhin-retire", phase: .ready)
        record.platform = "github"
        record.runtime = RuntimeID.tart.rawValue
        engine.store.upsert(record)
        let watcher = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(30)) }  // test cleanup cancels it
        defer { watcher.cancel() }
        engine.lifecycleTasks.withLock { $0[record.id] = watcher }

        await engine.deleteVMRecord(id: record.id, reason: "scale down")

        XCTAssertEqual(deletes.withLock { $0 }, 1)
        XCTAssertTrue(tart.deleteCalls.isEmpty)
        XCTAssertFalse(watcher.isCancelled, "a rejected retirement must leave the job's watcher running")
        XCTAssertEqual(engine.store.all.first?.phase, .ready)
    }

    func testEphemeralBusyPhaseSurvivesAnIdleRunnerSnapshotUntilDeregistration() async throws {
        let github = FakeGitHub()
        let tart = FakeTart()
        let engine = FleetEngine(
            config: makeTestConfig(), github: github, tart: tart,
            store: makeTestStore(), ssh: FakeSSH(), host: testHost,
            dependencies: .init(tokenLoader: { _, _ in "test-token" }, exitWatchInterval: .milliseconds(20)))
        github.queueDepth = 1
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { await engine.status().records.first?.phase == .ready }
        let vm = try XCTUnwrap(engine.store.all.first?.id)
        github.register(name: vm, busy: true)
        try await waitUntil(timeout: 10) { await engine.status().records.first?.phase == .busy }
        let previousReads = github.listRunnersCallCount
        github.runnersByID = github.runnersByID.mapValues {
            GHRunner(id: $0.id, name: $0.name, status: "online", busy: false, labels: [])
        }
        try await waitUntil(timeout: 10) { github.listRunnersCallCount >= previousReads + 2 }
        XCTAssertEqual(engine.store.all.first?.phase, .busy)
        github.queueDepth = 0
        try await engine.reconcileOnce()
        await engine.settleDeletes()
        XCTAssertTrue(tart.deleteCalls.isEmpty)
        github.deregister(name: vm)
        try await waitUntil(timeout: 10) { engine.store.all.isEmpty }
    }
}
