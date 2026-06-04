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
    case missingGatewayURL

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
        case .missingGatewayURL:
            return "Enter your gateway address, or paste a full setup code from openclaw qr."
        }
    }
}

nonisolated public enum SetupCodeDecoder {
    public static let lastGatewayURLDefaultsKey = "openwatch.lastGatewayURL"

    /// Normalizes user input into a gateway base URL (adds `ws://` when scheme is omitted).
    public static func normalizeGatewayURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.host != nil {
            return url
        }
        if !trimmed.contains("://") {
            return URL(string: "ws://\(trimmed)")
        }
        return nil
    }

    /// Decodes the opaque setup code from `openclaw qr` / `openclaw qr --setup-code-only`.
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

    /// Resolves pairing input for onboarding: full setup code and/or manual gateway address + bootstrap token.
    public static func resolvePairingInput(gatewayURLInput: String, setupCodeInput: String) throws -> PairingSetupPayload {
        let urlField = gatewayURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let codeField = setupCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !codeField.isEmpty else {
            AppLog.error("resolvePairingInput failed: empty setup code")
            throw SetupCodeDecoderError.empty
        }

        if let decoded = try? decode(codeField) {
            if let overrideURL = normalizeGatewayURL(urlField) {
                AppLog.info(
                    "resolvePairingInput: full setup code + manual gateway override host=\(overrideURL.host ?? "unknown")"
                )
                return PairingSetupPayload(gatewayURL: overrideURL, bootstrapToken: decoded.bootstrapToken)
            }
            AppLog.info("resolvePairingInput: using gateway host from setup code=\(decoded.gatewayURL.host ?? "unknown")")
            return decoded
        }

        guard let gatewayURL = normalizeGatewayURL(urlField) else {
            if urlField.isEmpty {
                AppLog.error("resolvePairingInput failed: token-only without gateway URL")
                throw SetupCodeDecoderError.missingGatewayURL
            }
            AppLog.error("resolvePairingInput failed: invalid gateway URL=\(urlField)")
            throw SetupCodeDecoderError.invalidURL(urlField)
        }

        AppLog.info(
            "resolvePairingInput: manual gateway host=\(gatewayURL.host ?? "unknown") bootstrapTokenLength=\(codeField.count)"
        )
        return PairingSetupPayload(gatewayURL: gatewayURL, bootstrapToken: codeField)
    }

    public static func saveLastGatewayURL(_ url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: lastGatewayURLDefaultsKey)
        AppLog.info("Saved last gateway URL host=\(url.host ?? "unknown")")
    }

    public static func loadLastGatewayURL() -> String? {
        guard let raw = UserDefaults.standard.string(forKey: lastGatewayURLDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else {
            return nil
        }
        return raw
    }
}
