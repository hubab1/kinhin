import Foundation

/// The configured CPU and RAM assigned when an instance starts. Persisted with
/// the instance so a reload cannot resize an already-running VM on paper.
public struct VMResourceReservation: Codable, Sendable, Equatable {
    public var cpu: Int
    public var memoryGB: Int

    public init(cpu: Int, memoryGB: Int) {
        self.cpu = cpu
        self.memoryGB = memoryGB
    }

    var isValid: Bool { cpu > 0 && memoryGB > 0 }
}
