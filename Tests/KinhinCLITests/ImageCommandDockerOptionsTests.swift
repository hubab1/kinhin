import XCTest

@testable import KinhinKit
@testable import kinhin

final class ImageCommandDockerOptionsTests: XCTestCase {
    private func config() -> KinhinConfig {
        var config = KinhinConfig.default
        config.docker = .init(image: "ci", platform: .amd64)
        config.toolchainCache = .init(autoPrune: false, maxAgeDays: 7, maxGB: 48)
        return config
    }

    func testDockerConfigPlatformAndCachePolicyReachTheBake() throws {
        let config = config()
        let options = try ImageCommand.dockerBakeOptions(
            args: ["--docker"], config: config, image: "ubuntu:24.04", target: "ci")
        XCTAssertEqual(options.platform, .amd64)
        XCTAssertEqual(options.cachePolicy, config.toolchainCache)
    }

    func testExplicitPlatformOverridesConfigWithoutDroppingCachePolicy() throws {
        let config = config()
        let options = try ImageCommand.dockerBakeOptions(
            args: ["--docker", "--platform", "linux/arm64"], config: config, image: "ubuntu:24.04", target: "ci")
        XCTAssertEqual(options.platform, .arm64)
        XCTAssertEqual(options.cachePolicy, config.toolchainCache)
    }

    func testInvalidExplicitPlatformIsRejected() {
        XCTAssertThrowsError(
            try ImageCommand.dockerBakeOptions(
                args: ["--docker", "--platform", "s390x"], config: config(), image: "ubuntu:24.04", target: "ci")
        ) { error in
            XCTAssertEqual(CLIExit(error), .usage)
        }
    }
}
