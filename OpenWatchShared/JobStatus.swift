import Foundation

nonisolated public enum JobStatus: String, Codable, Sendable, CaseIterable {
    case idle
    case listening
    case sending
    case running
    case done
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .done, .failed, .cancelled:
            return true
        default:
            return false
        }
    }
}
