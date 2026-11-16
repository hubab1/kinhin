import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// A prepare must not silently replace the host's disabled cache policy with
/// defaults: native image bands can live beside regenerable downloads.
final class ImagePreparationCachePolicyTests: XCTestCase {
    private var dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinhin-prepare-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        bestEffort("test", "remove isolated cache-policy fixture") { try FileManager.default.removeItem(at: dir) }
    }

    private func stalePayload(in cache: URL) throws -> URL {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let payload = cache.appendingPathComponent("retained-band")
        try Data("cached build products".utf8).write(to: payload)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60 * 86_400)], ofItemAtPath: payload.path)
        return payload
    }

    private func config(policy: KinhinConfig.ToolchainCacheConfig?) -> KinhinConfig {
        var config = makeTestConfig()
        config.toolchainCache = policy
        config.projects = [
            .init(pattern: "acme/api", toolchains: .init(specs: ["node@22"]), shareCache: true)
        ]
        return config
    }

    /// This is the real filesystem-prune contract at the VM bake boundary,
    /// with a temporary cache in place of the host cache and no VM boot.
    private func bake(tart: FakeTart, cache: URL) -> ProjectImageBuilder.Bake {
        { options in
            ToolchainCachePruner(cacheRoot: cache).prune(policy: ToolchainCachePolicy(from: options.cachePolicy))
            tart.vms[options.target] = TartVM(name: options.target, source: "local", status: "stopped")
        }
    }

    func testEagerProjectPreparePreservesDisabledPolicyAndEnabledDefaultBehavior() async throws {
        let cases: [(String, KinhinConfig.ToolchainCacheConfig?, Bool)] = [
            ("disabled", KinhinConfig.ToolchainCacheConfig(autoPrune: false, maxAgeDays: 7, maxGB: 1), true),
            ("enabled", KinhinConfig.ToolchainCacheConfig(autoPrune: true, maxAgeDays: 7, maxGB: 1), false),
            ("long-retention", KinhinConfig.ToolchainCacheConfig(autoPrune: true, maxAgeDays: 90, maxGB: 1), true),
            ("default", nil, false),
        ]
        for (name, policy, retained) in cases {
            let cache = dir.appendingPathComponent(name)
            let payload = try stalePayload(in: cache)
            let tart = FakeTart()
            let service = ProjectImageService(
                config: config(policy: policy), tart: tart,
                store: ProjectImageStore(directory: dir), forge: nil,
                bake: bake(tart: tart, cache: cache))

            let result = try await service.prepare(repository: "acme/api", ref: nil)

            XCTAssertTrue(result.baked)
            XCTAssertEqual(FileManager.default.fileExists(atPath: payload.path), retained, name)
        }
    }

    func testEngineProjectPreparePreservesDisabledPolicy() async throws {
        let cache = dir.appendingPathComponent("engine-cache")
        let payload = try stalePayload(in: cache)
        let tart = FakeTart()
        var dependencies = FleetEngine.Dependencies()
        dependencies.projectImageStore = ProjectImageStore(directory: dir)
        dependencies.projectBake = bake(tart: tart, cache: cache)
        let engine = FleetEngine(
            config: config(policy: .init(autoPrune: false, maxAgeDays: 7, maxGB: 1)), github: FakeGitHub(),
            tart: tart, store: makeTestStore(), ssh: FakeSSH(), host: testHost, dependencies: dependencies)

        _ = try await engine.projectImages.request(toolchains: .init(specs: ["node@22"]), shareCache: true)
        await engine.projectImages.waitForBakes()

        XCTAssertEqual(tart.vms.count, 1, "the prepare boundary was reached")
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
    }

    func testDockerPrepareUsesConfiguredPolicyWhileKeepingDefaultPruning() async throws {
        let cases: [(String, KinhinConfig.ToolchainCacheConfig?, Bool)] = [
            ("disabled", KinhinConfig.ToolchainCacheConfig(autoPrune: false, maxAgeDays: 7, maxGB: 1), true),
            ("enabled", KinhinConfig.ToolchainCacheConfig(autoPrune: true, maxAgeDays: 7, maxGB: 1), false),
            ("long-retention", KinhinConfig.ToolchainCacheConfig(autoPrune: true, maxAgeDays: 90, maxGB: 1), true),
            ("default", nil, false),
        ]
        for (name, policy, retained) in cases {
            let cache = dir.appendingPathComponent(name)
            let payload = try stalePayload(in: cache)
            let shell = FakeShell()
            let backend = LinuxImageBaker.Backend(
                logTag: "test", displayName: "docker", binary: "/fixture/docker", removeVerb: "rm",
                commit: { _, _, _ in })
            var options = ImageBuildService.dockerOptions(
                config: config(policy: policy), image: "ubuntu:24.04", target: "fixture-image")
            options.storedTokens = [.github]

            _ = try await LinuxImageBaker(shell: shell, backend: backend, cacheRoot: cache).prepare(
                options, versions: .init(github: "1", gitea: "1"))

            XCTAssertEqual(FileManager.default.fileExists(atPath: payload.path), retained, name)
            let run = try XCTUnwrap(shell.calls.first { $0.contains("run") })
            XCTAssertTrue(run.contains(ToolchainCacheMount.volumeSpec(host: cache.path)))
        }
    }
}
