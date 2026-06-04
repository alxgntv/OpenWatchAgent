import Foundation

enum GatewayJobError: LocalizedError {
    case notPaired
    case missingOperatorToken
    case invalidWebSocketURL
    case challengeTimeout
    case connectFailed(String)
    case runFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notPaired:
            return "Not connected to a gateway. Pair on iPhone first."
        case .missingOperatorToken:
            return "Missing operator token. Disconnect and pair again on iPhone."
        case .invalidWebSocketURL:
            return "Gateway WebSocket URL is invalid."
        case .challengeTimeout:
            return "Gateway did not send a connect challenge."
        case .connectFailed(let reason):
            return "Gateway connect failed: \(reason)"
        case .runFailed(let reason):
            return "Agent run failed: \(reason)"
        case .timedOut:
            return "Agent did not respond in time."
        }
    }
}

actor GatewayJobClient {
    private let appVersion: String
    /// We never cap how long an agent run may take. This is only the "connection is dead" window: if NO frame at all
    /// (not even a `tick` keepalive) arrives for this long, we treat the socket as lost. The gateway ticks every
    /// ~15–30s, so a healthy-but-busy run keeps streaming and is never cut off.
    private let stallTimeoutSeconds: TimeInterval

    init(
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        stallTimeoutSeconds: TimeInterval = 90
    ) {
        self.appVersion = appVersion
        self.stallTimeoutSeconds = stallTimeoutSeconds
    }

    /// Runs a chat turn. `onProgress` streams the live chain of what OpenClaw is doing (operations, tools, thinking)
    /// so the iPhone/Watch can show it. The run only fails on a real connection stall, not on a long-but-active agent.
    func runCommand(
        transcript: String,
        sessionKey: String,
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        AppLog.info("Submitting voice job via chat.send sessionKey=\(sessionKey) transcriptLength=\(transcript.count)")

        guard KeychainStore.isPaired, let gatewayURL = KeychainStore.loadGatewayURL() else {
            AppLog.error("runCommand blocked: not paired")
            throw GatewayJobError.notPaired
        }
        guard let operatorToken = KeychainStore.loadOperatorToken() else {
            AppLog.error("runCommand blocked: missing operator token")
            throw GatewayJobError.missingOperatorToken
        }

        let operatorScopes = KeychainStore.loadOperatorScopes()
        let identity = try DeviceIdentityStore.loadOrCreate()
        let wsURL = try websocketURL(from: gatewayURL)

        let task = URLSession.shared.webSocketTask(with: wsURL)
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
        }

        let nonce = try await waitForChallenge(on: task)
        AppLog.info("Job WS received connect.challenge")

        let connectId = UUID().uuidString
        try await sendConnect(
            on: task,
            connectId: connectId,
            identity: identity,
            operatorToken: operatorToken,
            operatorScopes: operatorScopes,
            nonce: nonce
        )
        try await waitForHelloOk(on: task, connectId: connectId)
        AppLog.info("Job WS operator handshake succeeded")

        // Subscribe to this session's live transcript/operation/tool events so we can stream the chain to the client.
        try await sendSessionMessagesSubscribe(on: task, sessionKey: sessionKey)
        AppLog.info("Subscribed to session messages sessionKey=\(sessionKey)")

        let chatSendId = UUID().uuidString
        try await sendChatSend(
            on: task,
            chatSendId: chatSendId,
            sessionKey: sessionKey,
            message: transcript
        )
        AppLog.info("chat.send dispatched sessionKey=\(sessionKey) id=\(chatSendId)")
        onProgress("Sent. Waiting for agent…")

        let reply = try await waitForReply(on: task, sessionKey: sessionKey, chatSendId: chatSendId, onProgress: onProgress)
        AppLog.info("chat.send reply received length=\(reply.count)")
        return reply
    }

    private func sendSessionMessagesSubscribe(on task: URLSessionWebSocketTask, sessionKey: String) async throws {
        let frame: [String: Any] = [
            "type": "req",
            "id": UUID().uuidString,
            "method": "sessions.messages.subscribe",
            "params": [
                "sessionKey": sessionKey,
            ],
        ]
        try await sendJSON(frame, on: task)
    }

    private func sendConnect(
        on task: URLSessionWebSocketTask,
        connectId: String,
        identity: DeviceIdentityMaterial,
        operatorToken: String,
        operatorScopes: [String],
        nonce: String
    ) async throws {
        let signedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        let signaturePayload = DeviceAuthPayloadBuilder.buildV2(
            deviceId: identity.deviceId,
            clientId: GatewayClientProfile.clientId,
            clientMode: GatewayClientProfile.operatorMode,
            role: GatewayClientProfile.operatorRole,
            scopes: operatorScopes,
            signedAtMs: signedAtMs,
            token: operatorToken,
            nonce: nonce
        )
        let signature = try identity.sign(payload: signaturePayload)

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
                    "mode": GatewayClientProfile.operatorMode,
                ],
                "role": GatewayClientProfile.operatorRole,
                "scopes": operatorScopes,
                "caps": [] as [String],
                "commands": [] as [String],
                "permissions": [:] as [String: Bool],
                "auth": [
                    "deviceToken": operatorToken,
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
    }

    private func sendChatSend(
        on task: URLSessionWebSocketTask,
        chatSendId: String,
        sessionKey: String,
        message: String
    ) async throws {
        let chatFrame: [String: Any] = [
            "type": "req",
            "id": chatSendId,
            "method": "chat.send",
            "params": [
                "sessionKey": sessionKey,
                "message": message,
                "idempotencyKey": UUID().uuidString,
                "deliver": false,
            ],
        ]
        try await sendJSON(chatFrame, on: task)
    }

    private func waitForHelloOk(on task: URLSessionWebSocketTask, connectId: String) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let json = try await receiveJSON(on: task, timeoutSeconds: 15)
            guard (json["type"] as? String) == "res", (json["id"] as? String) == connectId else {
                continue
            }
            if (json["ok"] as? Bool) == true,
               let payload = json["payload"] as? [String: Any],
               (payload["type"] as? String) == "hello-ok" {
                return
            }
            if let error = json["error"] as? [String: Any] {
                let message = (error["message"] as? String) ?? (error["code"] as? String) ?? "unknown"
                AppLog.error("Job WS connect error: \(message)")
                throw GatewayJobError.connectFailed(message)
            }
            throw GatewayJobError.connectFailed("Unexpected connect response")
        }
        throw GatewayJobError.connectFailed("Handshake timed out")
    }

    private func waitForReply(
        on task: URLSessionWebSocketTask,
        sessionKey: String,
        chatSendId: String,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        var latestText = ""
        var lastProgress = ""
        var sawAssistantDelta = false

        func emit(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != lastProgress else { return }
            lastProgress = trimmed
            onProgress(trimmed)
        }

        // No run cap: we wait as long as the agent keeps working. The only exit besides final/error is a dead socket,
        // detected when receiveJSON sees no frame at all within the stall window.
        while true {
            let json: [String: Any]
            do {
                json = try await receiveJSON(on: task, timeoutSeconds: stallTimeoutSeconds)
            } catch {
                AppLog.error("Job WS stalled with no frames for \(stallTimeoutSeconds)s; connection lost")
                throw GatewayJobError.timedOut
            }

            let type = json["type"] as? String

            // Diagnostic: log every frame so we can see exactly what OpenClaw streams (event names + payload shape).
            AppLog.info("WSFRAME \(describeFrame(json))")

            if type == "res", (json["id"] as? String) == chatSendId, (json["ok"] as? Bool) == false {
                let error = json["error"] as? [String: Any]
                let message = (error?["message"] as? String) ?? (error?["code"] as? String) ?? "chat.send rejected"
                AppLog.error("chat.send rejected: \(message)")
                throw GatewayJobError.runFailed(message)
            }

            guard type == "event", let event = json["event"] as? String else { continue }
            let payload = json["payload"] as? [String: Any] ?? [:]

            // Live chain of what OpenClaw is doing for this session (operations, tools, transcript steps).
            if event == "session.operation" || event == "session.tool" || event == "session.message" || event == "agent" {
                if eventSessionKey(payload) == nil || eventSessionKey(payload) == sessionKey,
                   let step = progressString(event: event, payload: payload) {
                    emit(step)
                }
                continue
            }

            guard event == "chat", (payload["sessionKey"] as? String) == sessionKey else { continue }

            let state = (payload["state"] as? String) ?? ""
            if let text = extractAssistantText(from: payload) {
                latestText = text
            }

            switch state {
            case "delta":
                if !sawAssistantDelta {
                    sawAssistantDelta = true
                    emit("Responding…")
                }
                continue
            case "final":
                let finalText = extractAssistantText(from: payload) ?? latestText
                guard !finalText.isEmpty else {
                    throw GatewayJobError.runFailed("Agent returned an empty response.")
                }
                return finalText
            case "error":
                let message = (payload["errorMessage"] as? String) ?? "Agent run failed."
                AppLog.error("chat run error: \(message)")
                throw GatewayJobError.runFailed(message)
            default:
                continue
            }
        }
    }

    /// Compact one-line description of a frame for diagnostics: type, event/id, and a truncated JSON of the payload.
    private func describeFrame(_ json: [String: Any]) -> String {
        let type = (json["type"] as? String) ?? "?"
        let event = (json["event"] as? String) ?? ""
        let id = (json["id"] as? String) ?? ""
        var payloadString = ""
        if let payload = json["payload"],
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let raw = String(data: data, encoding: .utf8) {
            payloadString = raw.count > 600 ? String(raw.prefix(600)) + "…" : raw
        }
        return "type=\(type) event=\(event) id=\(id) payload=\(payloadString)"
    }

    private func eventSessionKey(_ payload: [String: Any]) -> String? {
        if let key = payload["sessionKey"] as? String { return key }
        if let session = payload["session"] as? [String: Any], let key = session["key"] as? String { return key }
        return nil
    }

    /// Builds a short, human-readable status line from a streamed session/agent event.
    private func progressString(event: String, payload: [String: Any]) -> String? {
        func firstString(_ keys: [String]) -> String? {
            for key in keys {
                if let value = payload[key] as? String, !value.isEmpty { return value }
            }
            return nil
        }

        switch event {
        case "session.tool":
            let name = firstString(["tool", "name", "toolName", "title", "label"]) ?? "tool"
            let status = firstString(["status", "state", "phase"])
            return status != nil ? "Tool: \(name) (\(status!))" : "Tool: \(name)"
        case "session.operation":
            let label = firstString(["label", "title", "kind", "operation", "name", "type"]) ?? "operation"
            let status = firstString(["status", "state", "phase"])
            return status != nil ? "\(label) (\(status!))" : label
        case "agent":
            if let status = firstString(["status", "state", "phase"]) { return "Agent: \(status)" }
            return "Working…"
        case "session.message":
            if let role = firstString(["role"]), role != "assistant" { return nil }
            return nil
        default:
            return nil
        }
    }

    private func extractAssistantText(from payload: [String: Any]) -> String? {
        guard let message = payload["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return nil
        }
        let parts = content.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }
        let joined = parts.joined()
        return joined.isEmpty ? nil : joined
    }

    private func websocketURL(from gatewayURL: URL) throws -> URL {
        var components = URLComponents()
        components.scheme = gatewayURL.scheme == "wss" || gatewayURL.scheme == "https" ? "wss" : "ws"
        components.host = gatewayURL.host
        components.port = gatewayURL.port
        components.path = gatewayURL.path.isEmpty ? "/" : gatewayURL.path
        guard let url = components.url else {
            throw GatewayJobError.invalidWebSocketURL
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
                return nonce
            case .data:
                continue
            @unknown default:
                continue
            }
        }
        throw GatewayJobError.challengeTimeout
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
                throw GatewayJobError.timedOut
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
            throw GatewayJobError.runFailed("Malformed gateway frame")
        }
        return json
    }
}
