import Foundation

nonisolated public enum PairingPhase: String, Codable, Sendable {
    case needsSetupCode
    case connecting
    case waitingForApproval
    case connected
    case failed
}

nonisolated public struct PairingSnapshot: Codable, Sendable, Equatable {
    public var phase: PairingPhase
    public var gatewayURL: String?
    public var message: String?
    public var deviceId: String?

    public init(
        phase: PairingPhase = .needsSetupCode,
        gatewayURL: String? = nil,
        message: String? = nil,
        deviceId: String? = nil
    ) {
        self.phase = phase
        self.gatewayURL = gatewayURL
        self.message = message
        self.deviceId = deviceId
    }
}
