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
    case unrecognized
    case missingBootstrapToken
    case invalidURL(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Setup code is empty."
        case .unrecognized:
            return "Setup code not recognized or uses an insecure ws:// gateway URL."
        case .missingBootstrapToken:
            return "Setup code is missing a bootstrap token."
        case .invalidURL(let raw):
            return "Gateway URL is invalid: \(raw)"
        }
    }
}

nonisolated public enum SetupCodeDecoder {
    public static let lastGatewayURLDefaultsKey = "openwatch.lastGatewayURL"

    private struct SetupPayload: Decodable {
        let url: String?
        let host: String?
        let port: Int?
        let tls: Bool?
        let bootstrapToken: String?
        let token: String?
        let password: String?
    }

    private struct ResolvedSetupLink: Sendable {
        let gatewayURL: URL
        let bootstrapToken: String?
    }

    // ─── Ariadne's Thread [AT-0152] ─────────────────────
    // What: Parse setup input like official OpenClaw iOS (base64, JSON, Telegram copy, deep link).
    // Why:  Single-field pairing — URL and bootstrap token come from the setup code alone.
    // Date: 2026-06-11
    // Related: [AT-0152] OpenWatch/Views/SetupCodeEntryView.swift
    // ─────────────────────────────────────────────────────
    public static func resolvePairingInput(_ setupCodeInput: String) throws -> PairingSetupPayload {
        let trimmed = setupCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            AppLog.error("resolvePairingInput failed: empty setup code")
            throw SetupCodeDecoderError.empty
        }

        guard let resolved = resolveFromSetupInput(trimmed) else {
            AppLog.error("resolvePairingInput failed: setup code not recognized inputLength=\(trimmed.count)")
            throw SetupCodeDecoderError.unrecognized
        }

        guard let bootstrapToken = resolved.bootstrapToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bootstrapToken.isEmpty
        else {
            AppLog.error(
                "resolvePairingInput failed: missing bootstrapToken host=\(resolved.gatewayURL.host ?? "unknown")"
            )
            throw SetupCodeDecoderError.missingBootstrapToken
        }

        AppLog.info(
            "resolvePairingInput: host=\(resolved.gatewayURL.host ?? "unknown") port=\(resolved.gatewayURL.port ?? 0) bootstrapTokenLength=\(bootstrapToken.count)"
        )
        return PairingSetupPayload(gatewayURL: resolved.gatewayURL, bootstrapToken: bootstrapToken)
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

    private static func resolveFromSetupInput(_ input: String) -> ResolvedSetupLink? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let link = resolveFromSetupCode(trimmed) {
            return link
        }
        if let url = URL(string: trimmed),
           let link = resolveGatewayDeepLink(url)
        {
            return link
        }
        return resolveFromGatewayURLString(
            trimmed,
            bootstrapToken: nil,
            token: nil,
            password: nil)
    }

    private static func resolveFromSetupCode(_ code: String) -> ResolvedSetupLink? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let link = decodeSetupPayload(from: Data(trimmed.utf8)) {
            return link
        }
        if let data = decodeBase64Url(trimmed),
           let link = decodeSetupPayload(from: data)
        {
            return link
        }
        for candidate in setupCodeCandidates(in: trimmed) where candidate != trimmed {
            if let data = decodeBase64Url(candidate),
               let link = decodeSetupPayload(from: data)
            {
                return link
            }
        }
        return nil
    }

    private static func decodeSetupPayload(from data: Data) -> ResolvedSetupLink? {
        guard let payload = try? JSONDecoder().decode(SetupPayload.self, from: data) else { return nil }
        if let urlString = payload.url?.trimmingCharacters(in: .whitespacesAndNewlines),
           !urlString.isEmpty
        {
            return resolveFromGatewayURLString(
                urlString,
                bootstrapToken: payload.bootstrapToken,
                token: payload.token,
                password: payload.password)
        }
        guard let host = payload.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty
        else {
            return nil
        }
        let tls = payload.tls ?? true
        if !tls, !LoopbackHost.isLocalNetworkHost(host) {
            return nil
        }
        let scheme = tls ? "wss" : "ws"
        let port = payload.port ?? (tls ? 443 : 18789)
        guard let gatewayURL = URL(string: "\(scheme)://\(host):\(port)") else { return nil }
        return ResolvedSetupLink(
            gatewayURL: gatewayURL,
            bootstrapToken: payload.bootstrapToken ?? payload.token)
    }

    private static func resolveFromGatewayURLString(
        _ urlString: String,
        bootstrapToken: String?,
        token: String?,
        password: String?) -> ResolvedSetupLink?
    {
        guard let parsed = URLComponents(string: urlString),
              let hostname = parsed.host, !hostname.isEmpty
        else { return nil }

        let scheme = (parsed.scheme ?? "ws").lowercased()
        guard scheme == "ws" || scheme == "wss" || scheme == "http" || scheme == "https" else {
            return nil
        }
        let tls = scheme == "wss" || scheme == "https"
        if !tls, !LoopbackHost.isLocalNetworkHost(hostname) {
            return nil
        }
        let resolvedScheme = tls ? "wss" : "ws"
        let port = parsed.port ?? (tls ? 443 : 18789)
        guard let gatewayURL = URL(string: "\(resolvedScheme)://\(hostname):\(port)") else { return nil }
        let resolvedBootstrap = bootstrapToken ?? token
        _ = password
        return ResolvedSetupLink(gatewayURL: gatewayURL, bootstrapToken: resolvedBootstrap)
    }

    private static func resolveGatewayDeepLink(_ url: URL) -> ResolvedSetupLink? {
        guard url.scheme?.lowercased() == "openclaw" else { return nil }
        guard let host = url.host?.lowercased(), host == "gateway" else { return nil }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        let query = (comps.queryItems ?? []).reduce(into: [String: String]()) { dict, item in
            guard let value = item.value else { return }
            dict[item.name] = value
        }

        guard let hostParam = query["host"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hostParam.isEmpty
        else {
            return nil
        }
        let port = query["port"].flatMap { Int($0) } ?? 18789
        let tls = (query["tls"] as NSString?)?.boolValue ?? false
        if !tls, !LoopbackHost.isLocalNetworkHost(hostParam) {
            return nil
        }
        let scheme = tls ? "wss" : "ws"
        guard let gatewayURL = URL(string: "\(scheme)://\(hostParam):\(port)") else { return nil }
        return ResolvedSetupLink(
            gatewayURL: gatewayURL,
            bootstrapToken: query["token"])
    }

    private static func decodeBase64Url(_ input: String) -> Data? {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(contentsOf: String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }

    private static func setupCodeCandidates(in input: String) -> [String] {
        let surroundingPunctuation = CharacterSet(charactersIn: "`'\"“”‘’()[]{}<>.,;:")
        return input
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(surroundingPunctuation)) }
            .filter { candidate in
                guard candidate.count >= 24 else { return false }
                return candidate.allSatisfy { ch in
                    ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "="
                }
            }
    }
}
