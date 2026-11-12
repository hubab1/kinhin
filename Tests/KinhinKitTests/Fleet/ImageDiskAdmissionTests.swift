import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class ImageDiskAdmissionTests: XCTestCase {
    private func engine(diskGB: Int?) -> FleetEngine {
        var config = makeTestConfig()
        config.diskGB = diskGB
        return FleetEngine(
            config: config, github: FakeGitHub(), tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(),
            host: testHost)
    }

    func testExplicitFootprintAdmitsNamedAndDerivedImagesWithoutSpendingTheReserve() {
        let engine = engine(diskGB: 50)
        for name in ["xcode", "tahoe-base-p12345678"] {
            let slot = ScalePlan.Slot(account: "github", runtime: .tart, image: name)
            let listed = [TartVM(name: name, source: "base", status: "stopped", diskGB: 140)]
            XCTAssertEqual(engine.diskPerInstanceGB(slot, listed: listed), 50)
            let admitted = ScalePlan.admitByDisk([slot], freeDiskGB: 70, reserveGB: 20) {
                engine.diskPerInstanceGB($0, listed: listed)
            }
            XCTAssertEqual(admitted.admitted, [slot])
            XCTAssertNil(admitted.blocked)
            let held = ScalePlan.admitByDisk([slot], freeDiskGB: 69, reserveGB: 20) {
                engine.diskPerInstanceGB($0, listed: listed)
            }
            XCTAssertTrue(held.admitted.isEmpty)
            XCTAssertEqual(held.blocked?.neededGB, 70)
        }
    }

    func testOmittedOverrideKeepsListedImageSizeAndUnknownOrBaseFallbacks() {
        let engine = engine(diskGB: nil)
        let listed = [TartVM(name: "xcode", source: "base", status: "stopped", diskGB: 140)]
        XCTAssertEqual(
            engine.diskPerInstanceGB(.init(account: "github", runtime: .tart, image: "xcode"), listed: listed),
            140)
        for image in [nil, "unknown"] as [String?] {
            XCTAssertEqual(
                engine.diskPerInstanceGB(.init(account: "github", runtime: .tart, image: image), listed: listed),
                50)
        }
    }

    func testExplicitZeroFootprintAlsoOverridesImageSize() {
        let slot = ScalePlan.Slot(account: "github", runtime: .tart, image: "xcode")
        let listed = [TartVM(name: "xcode", source: "base", status: "stopped", diskGB: 140)]
        XCTAssertEqual(engine(diskGB: 0).diskPerInstanceGB(slot, listed: listed), 0)
    }

    func testOtherPoolsKeepTheirConfiguredOrDefaultFootprints() {
        for runtime in [RuntimeID.appleContainer, .docker] {
            let slot = ScalePlan.Slot(account: "github", runtime: runtime)
            XCTAssertEqual(engine(diskGB: 50).diskPerInstanceGB(slot, listed: []), 50)
            XCTAssertEqual(engine(diskGB: nil).diskPerInstanceGB(slot, listed: []), 8)
        }
    }
}
