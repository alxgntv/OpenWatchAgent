import Foundation

enum GatewayPairingError: LocalizedError {
    case invalidWebSocketURL
    case challengeTimeout
    case handshakeFailed(String)
    case waitingForApproval

    var errorDescription: String? {
        switch self {
        case .invalidWebSocketURL:
            return "Gateway WebSocket URL is invalid."
        case .challengeTimeout:
            return "Gateway did not send a connect challenge."
        case .handshakeFailed(let reason):
            return "Gateway handshake failed: \(reason)"
        case .waitingForApproval:
            return "Waiting for device approval on the gateway."
        }
    }
}

actor GatewayPairingClient {
    private let appVersion: String
    private let bootstrapScopes = [
        "operator.approvals",
        "operator.admin",
        "operator.read",
        "operator.talk.secrets",
        "operator.write",
    ]

    init(appVersion: String) {
        self.appVersion = appVersion
    }

    func connect(using payload: PairingSetupPayload) async throws -> PairingSnapshot {
        AppLog.info("Starting gateway pairing handshake")
        let identity = try DeviceIdentityStore.loadOrCreate()
        let wsURL = websocketURL(from: payload.gatewayURL)

        let task = URLSession.shared.webSocketTask(with: wsURL)
        task.resume()

        defer {
            task.cancel(with: .goingAway, reason: nil)
        }

        let nonce = try await waitForChallenge(on: task)
        let signedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        let authToken = payload.bootstrapToken
        let signaturePayload = DeviceAuthPayloadBuilder.buildV2(
            deviceId: identity.deviceId,
            clientId: GatewayClientProfile.clientId,
            clientMode: GatewayClientProfile.pairingMode,
            role: GatewayClientProfile.pairingRole,
            scopes: [],
            signedAtMs: signedAtMs,
            token: authToken,
            nonce: nonce
        )
        let signature = try identity.sign(payload: signaturePayload)

        let connectId = UUID().uuidString
        let connectFrame: [String: Any] = [
            "type": "req",
            "id": connectId,
            "method": "connect",
            "params": [
                "minProtocol": 3,
                "maxProtocol": 4,
                "client": [
                    "id": GatewayClientProfile.clientId,
                    "version": appVersion,
                    "platform": "ios",
                    "mode": GatewayClientProfile.pairingMode,
                ],
                "role": GatewayClientProfile.pairingRole,
                "scopes": [] as [String],
                "caps": [] as [String],
                "commands": [] as [String],
                "permissions": [:] as [String: Bool],
                "auth": [
                    "bootstrapToken": authToken,
                ],
                "locale": Locale.current.identifier,
                "userAgent": GatewayClientProfile.userAgent(appVersion: appVersion),
                "device": [
                    "id": identity.deviceId,
                    "publicKey": identity.publicKeyBase64URL,
                    "signature": signature,
                    "signedAt": signedAtMs,
                    "nonce": nonce,
                ],
            ],
        ]

        try await sendJSON(connectFrame, on: task)
        let response = try await receiveConnectResponse(on: task, matchingId: connectId, timeoutSeconds: 15)

        if
            let ok = response["ok"] as? Bool,
            ok,
            let payloadObject = response["payload"] as? [String: Any],
            (payloadObject["type"] as? String) == "hello-ok"
        {
            let deviceToken = extractDeviceToken(from: payloadObject)
            KeychainStore.saveGatewaySession(
                url: payload.gatewayURL,
                deviceToken: deviceToken,
                bootstrapToken: nil
            )
            if let operatorSession = extractOperatorSession(from: payloadObject) {
                KeychainStore.saveOperatorSession(token: operatorSession.token, scopes: operatorSession.scopes)
                AppLog.info("Stored operator handoff token scopes=\(operatorSession.scopes.joined(separator: ","))")
            } else {
                AppLog.error("hello-ok did not include an operator handoff token; chat.send will be unavailable until re-pair")
            }
            AppLog.info("Gateway pairing handshake succeeded")
            return PairingSnapshot(
                phase: .connected,
                gatewayURL: payload.gatewayURL.absoluteString,
                message: "Connected to your agent.",
                deviceId: identity.deviceId
            )
        }

        if let error = response["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? (error["code"] as? String) ?? "unknown"
            AppLog.error("Gateway connect error: \(message)")
            if message.lowercased().contains("pair") || message.lowercased().contains("approve") {
                KeychainStore.saveGatewaySession(
                    url: payload.gatewayURL,
                    deviceToken: nil,
                    bootstrapToken: nil
                )
                AppLog.info("Pairing gate reported; attempting immediate post-approval reconnect")
                if let recovered = try? await connectUsingPairedDeviceIdentity(gatewayURL: payload.gatewayURL) {
                    return recovered
                }
                AppLog.error("Post-approval reconnect failed after pairing gate")
                return PairingSnapshot(
                    phase: .waitingForApproval,
                    gatewayURL: payload.gatewayURL.absoluteString,
                    message: "Finishing setup…",
                    deviceId: identity.deviceId
                )
            }
            if isBootstrapTokenError(message) {
                throw GatewayPairingError.handshakeFailed(
                    "Setup code expired or already used. Ask for a fresh setup code and tap Connect once."
                )
            }
            throw GatewayPairingError.handshakeFailed(message)
        }

        AppLog.error("Connect response missing hello-ok and error frame")
        throw GatewayPairingError.handshakeFailed(
            "Unexpected gateway response. Ask for a fresh setup code and try again."
        )
    }

    private func isBootstrapTokenError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("bootstrap") && (lower.contains("invalid") || lower.contains("expired"))
    }

    func recheckApproval(gatewayURL: URL, bootstrapToken: String?) async throws -> PairingSnapshot {
        AppLog.info("Rechecking pairing approval gatewayURL=\(gatewayURL.host ?? "unknown")")
        do {
            return try await connectUsingPairedDeviceIdentity(gatewayURL: gatewayURL)
        } catch {
            if let bootstrapToken, !bootstrapToken.isEmpty {
                AppLog.info("Paired-device reconnect failed; retrying once with saved bootstrap token")
                return try await connect(
                    using: PairingSetupPayload(gatewayURL: gatewayURL, bootstrapToken: bootstrapToken)
                )
            }
            throw error
        }
    }

    /// Reconnect when this install's device identity is already approved on the gateway (bootstrap was consumed).
    /// Does not work after a full app delete: that creates a new device id and requires a fresh setup code.
    func connectUsingPairedDeviceIdentity(gatewayURL: URL) async throws -> PairingSnapshot {
        AppLog.info("Reconnecting with paired device identity (same install, post-approval)")
        let identity = try DeviceIdentityStore.loadOrCreate()
        let wsURL = websocketURL(from: gatewayURL)

        let task = URLSession.shared.webSocketTask(with: wsURL)
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
        }

        let nonce = try await waitForChallenge(on: task)
        let signedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        let signaturePayload = DeviceAuthPayloadBuilder.buildV2(
            deviceId: identity.deviceId,
            clientId: GatewayClientProfile.clientId,
            clientMode: GatewayClientProfile.pairingMode,
            role: GatewayClientProfile.pairingRole,
            scopes: [],
            signedAtMs: signedAtMs,
            token: nil,
            nonce: nonce
        )
        let signature = try identity.sign(payload: signaturePayload)

        let connectId = UUID().uuidString
        let connectFrame: [String: Any] = [
            "type": "req",
            "id": connectId,
            "method": "connect",
            "params": [
                "minProtocol": 3,
                "maxProtocol": 4,
                "client": [
                    "id": GatewayClientProfile.clientId,
                    "version": appVersion,
                    "platform": "ios",
                    "mode": GatewayClientProfile.pairingMode,
                ],
                "role": GatewayClientProfile.pairingRole,
                "scopes": [] as [String],
                "caps": [] as [String],
                "commands": [] as [String],
                "permissions": [:] as [String: Bool],
                "auth": [:] as [String: String],
                "locale": Locale.current.identifier,
                "userAgent": GatewayClientProfile.userAgent(appVersion: appVersion),
                "device": [
                    "id": identity.deviceId,
                    "publicKey": identity.publicKeyBase64URL,
                    "signature": signature,
                    "signedAt": signedAtMs,
                    "nonce": nonce,
                ],
            ],
        ]

        try await sendJSON(connectFrame, on: task)
        let response = try await receiveConnectResponse(on: task, matchingId: connectId, timeoutSeconds: 15)

        if
            let ok = response["ok"] as? Bool,
            ok,
            let payloadObject = response["payload"] as? [String: Any],
            (payloadObject["type"] as? String) == "hello-ok"
        {
            let deviceToken = extractDeviceToken(from: payloadObject)
            KeychainStore.saveGatewaySession(
                url: gatewayURL,
                deviceToken: deviceToken,
                bootstrapToken: nil
            )
            if let operatorSession = extractOperatorSession(from: payloadObject) {
                KeychainStore.saveOperatorSession(token: operatorSession.token, scopes: operatorSession.scopes)
                AppLog.info("Stored operator handoff token after approval reconnect")
            }
            AppLog.info("Paired-device reconnect succeeded")
            return PairingSnapshot(
                phase: .connected,
                gatewayURL: gatewayURL.absoluteString,
                message: "Connected to your agent.",
                deviceId: identity.deviceId
            )
        }

        if let error = response["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? (error["code"] as? String) ?? "unknown"
            AppLog.error("Paired-device reconnect error: \(message)")
            throw GatewayPairingError.handshakeFailed(message)
        }

        throw GatewayPairingError.handshakeFailed("Could not finish pairing. Ask for a new setup code.")
    }

    private func websocketURL(from gatewayURL: URL) -> URL {
        var components = URLComponents()
        components.scheme = gatewayURL.scheme == "wss" || gatewayURL.scheme == "https" ? "wss" : "ws"
        components.host = gatewayURL.host
        components.port = gatewayURL.port
        components.path = gatewayURL.path.isEmpty ? "/" : gatewayURL.path
        guard let url = components.url else {
            fatalError("invalid websocket url")
        }
        return url
    }

    private func waitForChallenge(on task: URLSessionWebSocketTask) async throws -> String {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let message = try await task.receive()
            switch message {
            case .string(let text):
                guard
                    let data = text.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    (json["event"] as? String) == "connect.challenge",
                    let payload = json["payload"] as? [String: Any],
                    let nonce = payload["nonce"] as? String
                else {
                    continue
                }
                AppLog.info("Received connect.challenge from gateway")
                return nonce
            case .data:
                continue
            @unknown default:
                continue
            }
        }
        throw GatewayPairingError.challengeTimeout
    }

    /// Reads frames until the `connect` response (`type: "res"` with the matching id) arrives.
    /// The gateway pushes server-initiated `event` frames (e.g. `voicewake.changed`,
    /// `voicewake.routing.changed`) to node clients right after connect, so the response
    /// frame is not guaranteed to be the first frame on the socket.
    private func receiveConnectResponse(
        on task: URLSessionWebSocketTask,
        matchingId connectId: String,
        timeoutSeconds: TimeInterval
    ) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let json = try await receiveJSON(on: task, timeoutSeconds: remaining)

            if (json["type"] as? String) == "event" || json["event"] != nil {
                AppLog.info("Skipping gateway event frame while awaiting connect response event=\(json["event"] as? String ?? "unknown")")
                continue
            }
            if let frameId = json["id"] as? String, frameId != connectId {
                AppLog.info("Skipping gateway frame with mismatched id while awaiting connect response")
                continue
            }
            return json
        }
        throw GatewayPairingError.challengeTimeout
    }

    private func sendJSON(_ object: [String: Any], on task: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await task.send(.string(text))
    }

    private func receiveJSON(on task: URLSessionWebSocketTask, timeoutSeconds: TimeInterval) async throws -> [String: Any] {
        let message = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask {
                try await task.receive()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw GatewayPairingError.challengeTimeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        let text: String
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            text = String(data: data, encoding: .utf8) ?? ""
        @unknown default:
            text = ""
        }

        guard
            let data = text.data(using: .utf8),
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw GatewayPairingError.handshakeFailed("Malformed gateway response")
        }
        return json
    }

    private func extractDeviceToken(from helloOK: [String: Any]) -> String? {
        if let auth = helloOK["auth"] as? [String: Any] {
            if let token = auth["deviceToken"] as? String { return token }
            if let token = auth["token"] as? String { return token }
        }
        return nil
    }

    private func extractOperatorSession(from helloOK: [String: Any]) -> (token: String, scopes: [String])? {
        guard let auth = helloOK["auth"] as? [String: Any] else { return nil }

        if (auth["role"] as? String) == "operator", let token = auth["deviceToken"] as? String {
            let scopes = (auth["scopes"] as? [String]) ?? []
            return (token, scopes)
        }

        if let extraTokens = auth["deviceTokens"] as? [[String: Any]] {
            for entry in extraTokens where (entry["role"] as? String) == "operator" {
                if let token = entry["deviceToken"] as? String {
                    let scopes = (entry["scopes"] as? [String]) ?? []
                    return (token, scopes)
                }
            }
        }
        return nil
    }
}
