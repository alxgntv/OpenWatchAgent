import Foundation

/// Wire identifiers must match OpenClaw gateway-protocol (`openclaw-ios`, modes `node` / `ui`).
nonisolated public enum GatewayClientProfile {
    public static let clientId = "openclaw-ios"
    public static let pairingRole = "node"
    public static let pairingMode = "node"
    public static let operatorRole = "operator"
    public static let operatorMode = "ui"

    public static func userAgent(appVersion: String) -> String {
        "openclaw-ios/\(appVersion)"
    }
}
