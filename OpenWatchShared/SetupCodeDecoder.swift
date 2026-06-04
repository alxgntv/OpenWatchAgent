import Foundation

nonisolated public struct PairingSetupPayload: Sendable, Equatable {
    public let gatewayURL: URL
    public let bootstrapToken: String

    public init(gatewayURL: URL, bootstrapToken: String) {
        self.gatewayURL = gatewayURL
        self.bootstrapToken = bootstrapToken
    }
}

nonisolated public enum SetupCodeDecoderError: LocalizedError, Sendable {
    case empty
    case invalidEncoding
    case invalidJSON
    case missingFields
    case invalidURL(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Setup code is empty."
        case .invalidEncoding:
            return "Setup code encoding is invalid."
        case .invalidJSON:
            return "Setup code payload is invalid."
        case .missingFields:
            return "Setup code is missing required fields."
        case .invalidURL(let raw):
            return "Gateway URL is invalid: \(raw)"
        }
    }
}

nonisolated public enum SetupCodeDecoder {
    public static func decode(_ raw: String) throws -> PairingSetupPayload {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SetupCodeDecoderError.empty
        }

        let normalized = trimmed
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingLength = (4 - normalized.count % 4) % 4
        let padded = normalized + String(repeating: "=", count: paddingLength)

        guard let data = Data(base64Encoded: padded) else {
            throw SetupCodeDecoderError.invalidEncoding
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let urlString = object["url"] as? String,
            let bootstrapToken = object["bootstrapToken"] as? String,
            !bootstrapToken.isEmpty
        else {
            throw SetupCodeDecoderError.invalidJSON
        }

        guard let url = normalizeGatewayURL(urlString) else {
            throw SetupCodeDecoderError.invalidURL(urlString)
        }

        AppLog.info("Decoded setup code for gateway host=\(url.host ?? "unknown")")
        return PairingSetupPayload(gatewayURL: url, bootstrapToken: bootstrapToken)
    }

    private static func normalizeGatewayURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.host != nil {
            return url
        }
        if !trimmed.contains("://") {
            return URL(string: "ws://\(trimmed)")
        }
        return nil
    }
}
