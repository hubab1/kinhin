import XCTest

@testable import KinhinKit

final class DaemonAppAssociationTests: XCTestCase {
    func testBundledCLIAndItsSymlinkAssociateWithTheResponsibleApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("kinhin.app/Contents")
        let binary = contents.appendingPathComponent("Resources/bin/kinhin")
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: binary)
        let info: [String: String] = ["CFBundleIdentifier": "com.example.kinhin", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let link = root.appendingPathComponent("kinhin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
        for path in [binary.path, link.path] {
            let plist = Daemon.agentPlist(binaryPath: path, logs: root, environment: ["TART_HOME": "/Volumes/CI/tart"])
            let parsed = try PropertyListSerialization.propertyList(from: Data(plist.utf8), options: [], format: nil)
            let dictionary = try XCTUnwrap(parsed as? [String: Any])
            XCTAssertEqual(dictionary["AssociatedBundleIdentifiers"] as? [String], ["com.example.kinhin"])
            XCTAssertEqual(dictionary["EnvironmentVariables"] as? [String: String], ["TART_HOME": "/Volumes/CI/tart"])
        }
    }

    func testStandaloneCLIHasNoInventedAppAssociation() throws {
        let plist = Daemon.agentPlist(
            binaryPath: "/usr/local/bin/kinhin", logs: URL(fileURLWithPath: "/tmp"), environment: [:])
        let parsed = try PropertyListSerialization.propertyList(from: Data(plist.utf8), options: [], format: nil)
        let dictionary = try XCTUnwrap(parsed as? [String: Any])
        XCTAssertNil(dictionary["AssociatedBundleIdentifiers"])
    }
}
