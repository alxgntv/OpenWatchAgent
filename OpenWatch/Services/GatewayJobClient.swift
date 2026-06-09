import Foundation

struct GatewayJobDiagnostics: Sendable, Equatable {
    let failureSource: String
    let elapsedSinceSend: Double?
    let elapsedSinceLastWSFrame: Double?
    let elapsedSinceWorking: Double?
    let runId: String?
    let wsCloseCode: String?
    let backendErrorCode: String?
}

enum GatewayJobError: LocalizedError {
    case notPaired
    case missingOperatorToken
    case invalidWebSocketURL
    case challengeTimeout
    case connectFailed(String)
    case runFailed(String, GatewayJobDiagnostics? = nil)
    case timedOut(GatewayJobDiagnostics? = nil)

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
        case .runFailed(let reason, _):
            return "Agent run failed: \(reason)"
        case .timedOut:
            return "Agent did not respond in time."
        }
    }

    var diagnostics: GatewayJobDiagnostics? {
        switch self {
        case .runFailed(_, let diagnostics), .timedOut(let diagnostics):
            return diagnostics
        case .notPaired, .missingOperatorToken, .invalidWebSocketURL, .challengeTimeout, .connectFailed:
            return nil
        }
    }

    var isTimedOut: Bool {
        if case .timedOut = self { return true }
        return false
    }
}

/// One configured agent as reported by the gateway's `agents.list`.
struct GatewayAgentRow: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let emoji: String?
    let subtitle: String?
    let modelLabel: String?
    let isDefault: Bool

    /// UI label for the primary coordinator (`main` is always shown as Main Actor).
    var displayName: String {
        id == "main" ? "Main Actor" : name
    }
}

/// Parsed payload from `agents.list` (OpenClaw gateway RPC).
struct GatewayAgentsListResult: Sendable, Equatable {
    let defaultAgentId: String
    let agents: [GatewayAgentRow]
}

/// One real session as reported by the gateway's `sessions.list`.
struct GatewaySessionRow: Identifiable, Sendable, Equatable {
    let id: String              // sessionKey
    let title: String
    let preview: String?
    let updatedAt: Date?
    let messageCount: Int?
}

/// Aggregate usage computed from the gateway's `sessions.list` payload (per-session token fields summed).
struct GatewayUsage: Sendable, Equatable {
    let sessionCount: Int
    let totalTokens: Int
    let inputTokens: Int
    let outputTokens: Int
    let totalMessages: Int
    let lastActivityAt: Date?
    let model: String?
}

/// One real assistant text message as reported by the gateway's `chat.history`.
struct ChatHistoryMessage: Identifiable, Sendable, Equatable {
    let id: String
    let role: String
    let text: String
    let createdAt: Date?

    nonisolated var isUser: Bool { role.lowercased() == "user" }
}

struct SubmittedAudioJob: Sendable, Equatable {
    let chatSendId: String
    let acceptedAt: Date
    let historyBaselineAssistantCount: Int
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

        let task = try await openOperatorSocket()
        defer {
            task.cancel(with: .goingAway, reason: nil)
        }
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

    // ─── Ariadne's Thread [AT-0027] ─────────────────────
    // What: Send Watch audio as a chat.send attachment.
    // Why:  OpenClaw normalizes RPC attachments into inbound media and tools.media.audio transcribes the audio server-side.
    // Date: 2026-06-06
    // Related: app→AppModel handleWatchAudioFile, OpenClaw docs→Audio and voice notes
    // ─────────────────────────────────────────────────────
    func runAudioAttachment(
        audioData: Data,
        fileName: String,
        mimeType: String,
        sessionKey: String,
        idempotencyKey: String,
        jobId: UUID? = nil,
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        let jobLogId = iphoneJobLogId(jobId: jobId, fallback: idempotencyKey)
        await FlowLog.progress(step: 5, side: .iphone, flow: "audio-send-server", detail: "opening gateway websocket sessionKey=\(sessionKey) bytes=\(audioData.count) fileName=\(fileName) mimeType=\(mimeType)")
        AppLog.info("Submitting Watch audio attachment via chat.send sessionKey=\(sessionKey) bytes=\(audioData.count) fileName=\(fileName) mimeType=\(mimeType)")
        let task = try await openOperatorSocket()
        defer {
            task.cancel(with: .goingAway, reason: nil)
        }

        try await sendSessionMessagesSubscribe(on: task, sessionKey: sessionKey)

        let chatSendId = UUID().uuidString
        let sendStartedAt = Date()
        try await sendChatSend(
            on: task,
            chatSendId: chatSendId,
            sessionKey: sessionKey,
            message: "",
            idempotencyKey: idempotencyKey,
            attachments: [[
                "type": "audio",
                "fileName": fileName,
                "mimeType": mimeType,
                "content": audioData.base64EncodedString(),
            ]]
        )
        await FlowLog.progress(step: 5, side: .iphone, flow: "audio-send-server", detail: "chat.send audio dispatched sessionKey=\(sessionKey) id=\(chatSendId)")
        AppLog.info("chat.send audio attachment dispatched sessionKey=\(sessionKey) id=\(chatSendId)")
        onProgress("Sent audio. Transcribing…")

        let reply = try await waitForReply(on: task, sessionKey: sessionKey, chatSendId: chatSendId, jobLogId: jobLogId, sendStartedAt: sendStartedAt, onProgress: onProgress)
        await FlowLog.progress(step: 6, side: .iphone, flow: "server-response", detail: "gateway reply received length=\(reply.count) sessionKey=\(sessionKey)")
        AppLog.info("chat.send audio attachment reply received length=\(reply.count)")
        return reply
    }

    // ─── Ariadne's Thread [AT-0044] ─────────────────────
    // What: Submit Watch audio only until the gateway accepts chat.send, without waiting for the final assistant reply.
    // Why:  Locked/background iPhone cannot be kept alive for long runs; final replies are reconciled later from history.
    // Date: 2026-06-07
    // Related: [AT-0025] app→AppModel.handleWatchAudioFile, [AT-0027] GatewayJobClient.runAudioAttachment
    // ─────────────────────────────────────────────────────
    func submitAudioAttachment(
        audioData: Data,
        fileName: String,
        mimeType: String,
        sessionKey: String,
        idempotencyKey: String
    ) async throws -> SubmittedAudioJob {
        let baseline = (try? await fetchHistory(sessionKey: sessionKey).filter { !$0.isUser }.count) ?? 0
        await FlowLog.progress(step: 5, side: .iphone, flow: "audio-send-server", detail: "opening gateway websocket for accepted-only submit sessionKey=\(sessionKey) bytes=\(audioData.count) fileName=\(fileName) baselineAssistantCount=\(baseline)")
        AppLog.info("Submitting Watch audio until accepted sessionKey=\(sessionKey) bytes=\(audioData.count) baselineAssistantCount=\(baseline)")

        let task = try await openOperatorSocket()
        defer {
            task.cancel(with: .goingAway, reason: nil)
        }

        let chatSendId = UUID().uuidString
        try await sendChatSend(
            on: task,
            chatSendId: chatSendId,
            sessionKey: sessionKey,
            message: "",
            idempotencyKey: idempotencyKey,
            attachments: [[
                "type": "audio",
                "fileName": fileName,
                "mimeType": mimeType,
                "content": audioData.base64EncodedString(),
            ]]
        )
        try await waitForChatSendAccepted(on: task, chatSendId: chatSendId)
        AppLog.info("chat.send audio accepted sessionKey=\(sessionKey) id=\(chatSendId)")
        return SubmittedAudioJob(
            chatSendId: chatSendId,
            acceptedAt: Date(),
            historyBaselineAssistantCount: baseline
        )
    }

    func latestAssistantReplyAfterBaseline(sessionKey: String, baselineAssistantCount: Int) async throws -> String? {
        let messages = try await fetchHistory(sessionKey: sessionKey)
        let assistantMessages = messages.filter { !$0.isUser }
        guard assistantMessages.count > baselineAssistantCount else {
            AppLog.info("No new assistant reply yet sessionKey=\(sessionKey) assistantCount=\(assistantMessages.count) baseline=\(baselineAssistantCount)")
            return nil
        }
        let newMessages = assistantMessages.dropFirst(min(baselineAssistantCount, assistantMessages.count))
        let reply = newMessages.map(\.text).joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return reply.isEmpty ? nil : reply
    }

    func probeGatewayHelloOk() async -> String {
        do {
            let task = try await openOperatorSocket()
            task.cancel(with: .goingAway, reason: nil)
            AppLog.info("Gateway probe succeeded: WSS connect.challenge -> connect -> hello-ok")
            return "wss hello-ok"
        } catch {
            AppLog.error("Gateway probe failed: \(error.localizedDescription)")
            return "error=\(error.localizedDescription)"
        }
    }

    private func sendSessionMessagesSubscribe(on task: URLSessionWebSocketTask, sessionKey: String) async throws {
        let frame: [String: Any] = [
            "type": "req",
            "id": UUID().uuidString,
            "method": "sessions.messages.subscribe",
            "params": [
                "key": sessionKey,
            ],
        ]
        try await sendJSON(frame, on: task)
    }

    /// Opens a WebSocket and completes the operator handshake (challenge → connect → hello-ok).
    /// The caller owns the returned task and must cancel it when done.
    private func openOperatorSocket() async throws -> URLSessionWebSocketTask {
        guard let gatewayURL = KeychainStore.loadGatewayURL() else {
            AppLog.error("openOperatorSocket blocked: missing gateway URL")
            throw GatewayJobError.notPaired
        }
        guard let operatorToken = KeychainStore.loadOperatorToken() else {
            AppLog.error("openOperatorSocket blocked: missing operator token")
            throw GatewayJobError.missingOperatorToken
        }
        let operatorScopes = KeychainStore.loadOperatorScopes()
        let identity = try DeviceIdentityStore.loadOrCreate()
        let wsURL = try websocketURL(from: gatewayURL)

        let task = URLSession.shared.webSocketTask(with: wsURL)
        task.resume()

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
        return task
    }

    /// A warm, authenticated socket reused for read-only RPCs (sessions.list / chat.history) so we don't pay a full
    /// handshake on every call. It is dedicated to reads (never shared with the streaming runCommand socket).
    private var readSocket: URLSessionWebSocketTask?

    /// Fetches the real session index from the gateway (`sessions.list`). Field names are parsed defensively because
    /// the protocol schema is not fully pinned here; the raw payload is logged so parsing can be tuned to your gateway.
    func listSessions() async throws -> [GatewaySessionRow] {
        let payload = try await readRPC(method: "sessions.list", params: [:])
        AppLog.info("sessions.list raw payload=\(truncatedJSON(payload))")
        return parseSessions(payload)
    }

    /// Fetches configured agents from the gateway (`agents.list`). Same WS transport as sessions.list.
    func listAgents() async throws -> GatewayAgentsListResult {
        let payload = try await readRPC(method: "agents.list", params: [:])
        AppLog.info("agents.list raw payload=\(truncatedJSON(payload))")
        return parseAgents(payload)
    }

    /// Default workspace path used by agents on the user's gateway (matches OpenClaw docker layout).
    static let defaultAgentWorkspace = "/home/node/.openclaw/workspace"

    /// Creates a new agent on the gateway (`agents.create`, requires `operator.admin` on the operator token).
    func createAgent(
        name: String,
        workspace: String = defaultAgentWorkspace,
        emoji: String? = nil,
        model: String? = nil
    ) async throws -> String {
        var params: [String: Any] = [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "workspace": workspace.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        if let emoji, !emoji.trimmingCharacters(in: .whitespaces).isEmpty {
            params["emoji"] = emoji.trimmingCharacters(in: .whitespaces)
        }
        if let model, !model.trimmingCharacters(in: .whitespaces).isEmpty {
            params["model"] = model.trimmingCharacters(in: .whitespaces)
        }
        AppLog.info("agents.create name=\(params["name"] ?? "") workspace=\(params["workspace"] ?? "")")
        let payload = try await readRPC(method: "agents.create", params: params)
        if let agentId = payload["agentId"] as? String, !agentId.isEmpty {
            AppLog.info("agents.create succeeded agentId=\(agentId)")
            return agentId
        }
        AppLog.error("agents.create response missing agentId payload=\(truncatedJSON(payload))")
        throw GatewayJobError.runFailed("Gateway did not return an agent id.")
    }

    /// Fetches the session index once and returns both the parsed rows and aggregate usage (avoids a second RPC).
    func listSessionsAndUsage() async throws -> (rows: [GatewaySessionRow], usage: GatewayUsage) {
        let payload = try await readRPC(method: "sessions.list", params: [:])
        AppLog.info("sessions.list raw payload=\(truncatedJSON(payload))")
        return (parseSessions(payload), parseUsage(payload))
    }

    /// Fetches the real transcript for one session (`chat.history`). Parsed defensively + raw payload logged.
    func fetchHistory(sessionKey: String) async throws -> [ChatHistoryMessage] {
        let payload = try await readRPC(method: "chat.history", params: ["sessionKey": sessionKey])
        AppLog.info("chat.history raw payload=\(truncatedJSON(payload))")
        return parseHistory(payload)
    }

    /// Closes the warm read socket (e.g. on disconnect).
    func closeReadSocket() {
        readSocket?.cancel(with: .goingAway, reason: nil)
        readSocket = nil
    }

    /// Runs a read RPC on its own authenticated socket.
    private func readRPC(method: String, params: [String: Any]) async throws -> [String: Any] {
        let task = try await openOperatorSocket()
        defer { task.cancel(with: .goingAway, reason: nil) }
        let reqId = UUID().uuidString
        try await sendJSON([
            "type": "req",
            "id": reqId,
            "method": method,
            "params": params,
        ], on: task)
        AppLog.info("\(method) dispatched id=\(reqId) reused=false")
        return try await awaitResult(on: task, id: reqId)
    }

    private func readRPCOnce(method: String, params: [String: Any], reuseExisting: Bool) async throws -> [String: Any] {
        let task: URLSessionWebSocketTask
        if reuseExisting, let existing = readSocket {
            task = existing
        } else {
            task = try await openOperatorSocket()
            readSocket = task
        }
        let reqId = UUID().uuidString
        try await sendJSON([
            "type": "req",
            "id": reqId,
            "method": method,
            "params": params,
        ], on: task)
        AppLog.info("\(method) dispatched id=\(reqId) reused=\(reuseExisting && readSocket != nil)")
        return try await awaitResult(on: task, id: reqId)
    }

    /// Reads frames until the matching `res` arrives (skipping interleaved events), returns its payload or throws.
    private func awaitResult(on task: URLSessionWebSocketTask, id: String) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let json = try await receiveJSON(on: task, timeoutSeconds: min(remaining, 15))
            guard (json["type"] as? String) == "res", (json["id"] as? String) == id else { continue }
            if (json["ok"] as? Bool) == false {
                let error = json["error"] as? [String: Any]
                let message = (error?["message"] as? String) ?? (error?["code"] as? String) ?? "request failed"
                AppLog.error("RPC \(id) failed: \(message)")
                throw GatewayJobError.runFailed(message)
            }
            return (json["payload"] as? [String: Any]) ?? [:]
        }
        throw GatewayJobError.timedOut()
    }

    private func truncatedJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let raw = String(data: data, encoding: .utf8) else { return "<unserializable>" }
        return raw.count > 1500 ? String(raw.prefix(1500)) + "…" : raw
    }

    private func parseAgents(_ payload: [String: Any]) -> GatewayAgentsListResult {
        let defaultId = (payload["defaultId"] as? String) ?? "main"
        let rows = (payload["agents"] as? [[String: Any]]) ?? []
        let agents = rows.compactMap { row -> GatewayAgentRow? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            let identity = row["identity"] as? [String: Any]
            let name = (row["name"] as? String)
                ?? (identity?["name"] as? String)
                ?? id.capitalized
            let emoji = identity?["emoji"] as? String
            let theme = identity?["theme"] as? String
            let description = row["description"] as? String
            let subtitle = theme ?? description
            var modelLabel: String?
            if let model = row["model"] as? [String: Any], let primary = model["primary"] as? String {
                modelLabel = primary
            }
            let isDefault = (row["default"] as? Bool) == true || id == defaultId
            return GatewayAgentRow(
                id: id,
                name: name,
                emoji: emoji,
                subtitle: subtitle,
                modelLabel: modelLabel,
                isDefault: isDefault
            )
        }
        AppLog.info("Parsed \(agents.count) agents from agents.list defaultId=\(defaultId)")
        return GatewayAgentsListResult(defaultAgentId: defaultId, agents: agents)
    }

    private func parseSessions(_ payload: [String: Any]) -> [GatewaySessionRow] {
        let rows = (payload["sessions"] as? [[String: Any]])
            ?? (payload["rows"] as? [[String: Any]])
            ?? (payload["items"] as? [[String: Any]])
            ?? (payload["list"] as? [[String: Any]])
            ?? []
        let parsed = rows.compactMap { row -> GatewaySessionRow? in
            guard let key = (row["key"] as? String) ?? (row["sessionKey"] as? String) ?? (row["id"] as? String) else {
                return nil
            }
            let title = (row["title"] as? String) ?? (row["label"] as? String) ?? (row["name"] as? String) ?? key
            let preview = (row["preview"] as? String) ?? (row["lastMessage"] as? String) ?? (row["summary"] as? String)
            let updated = parseDate(row["updatedAt"]) ?? parseDate(row["lastActivityAt"]) ?? parseDate(row["lastMessageAt"]) ?? parseDate(row["mtimeMs"]) ?? parseDate(row["ts"])
            let count = (row["messageCount"] as? Int) ?? (row["count"] as? Int) ?? (row["messages"] as? Int)
            return GatewaySessionRow(id: key, title: title, preview: preview, updatedAt: updated, messageCount: count)
        }
        return parsed.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    /// Sums per-session token counters from the `sessions.list` payload and reads the session count + default model.
    private func parseUsage(_ payload: [String: Any]) -> GatewayUsage {
        let rows = (payload["sessions"] as? [[String: Any]])
            ?? (payload["rows"] as? [[String: Any]])
            ?? (payload["items"] as? [[String: Any]])
            ?? []
        var total = 0, input = 0, output = 0, messages = 0
        var lastActivity: Date? = nil
        for row in rows {
            total += intValue(row["totalTokens"])
            input += intValue(row["inputTokens"])
            output += intValue(row["outputTokens"])
            // Per-session message count, same defensive keys as parseSessions.
            messages += (row["messageCount"] as? Int) ?? (row["count"] as? Int) ?? (row["messages"] as? Int) ?? 0
            // Most recent activity across all sessions, same defensive keys as parseSessions.
            if let updated = parseDate(row["updatedAt"]) ?? parseDate(row["lastActivityAt"]) ?? parseDate(row["lastMessageAt"]) ?? parseDate(row["mtimeMs"]) ?? parseDate(row["ts"]) {
                if lastActivity == nil || updated > lastActivity! { lastActivity = updated }
            }
        }
        let count = (payload["count"] as? Int) ?? rows.count
        let model = (payload["defaults"] as? [String: Any])?["model"] as? String
        return GatewayUsage(
            sessionCount: count,
            totalTokens: total,
            inputTokens: input,
            outputTokens: output,
            totalMessages: messages,
            lastActivityAt: lastActivity,
            model: model
        )
    }

    private func intValue(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String, let i = Int(s) { return i }
        return 0
    }

    // ─── Ariadne's Thread [AT-0117] ─────────────────────
    // What: Keep only assistant text-block messages from OpenClaw chat.history.
    // Why:  Tool calls/results and user messages are transport noise for OpenWatch and must not be stored or mirrored.
    // Date: 2026-06-09
    // Related: app→GatewayJobClient.fetchHistory, shared→WatchHistoryMessage
    // ─────────────────────────────────────────────────────
    private func parseHistory(_ payload: [String: Any]) -> [ChatHistoryMessage] {
        let rows = (payload["messages"] as? [[String: Any]])
            ?? (payload["items"] as? [[String: Any]])
            ?? (payload["history"] as? [[String: Any]])
            ?? (payload["entries"] as? [[String: Any]])
            ?? []
        return rows.compactMap { row -> ChatHistoryMessage? in
            assistantTextMessage(from: row)
        }
    }

    private func assistantTextMessage(from row: [String: Any]) -> ChatHistoryMessage? {
        if let message = row["message"] as? [String: Any] {
            return assistantTextMessage(from: message)
        }
        guard (row["role"] as? String) == "assistant",
              let text = assistantTextBlocks(from: row),
              !text.isEmpty else {
            return nil
        }
        let id = (row["id"] as? String) ?? (row["messageId"] as? String) ?? UUID().uuidString
        let createdAt = parseDate(row["createdAt"]) ?? parseDate(row["timestamp"]) ?? parseDate(row["ts"]) ?? parseDate(row["time"])
        return ChatHistoryMessage(id: id, role: "assistant", text: text, createdAt: createdAt)
    }

    private func assistantTextBlocks(from row: [String: Any]) -> String? {
        guard let blocks = row["content"] as? [[String: Any]] else { return nil }
        let parts = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text",
                  let text = block["text"] as? String else {
                return nil
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : text
        }
        let joined = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private func parseDate(_ value: Any?) -> Date? {
        if let ms = value as? Double { return Date(timeIntervalSince1970: ms > 1_000_000_000_000 ? ms / 1000 : ms) }
        if let ms = value as? Int { return parseDate(Double(ms)) }
        if let iso = value as? String {
            let formatter = ISO8601DateFormatter()
            return formatter.date(from: iso)
        }
        return nil
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
        message: String,
        idempotencyKey: String = UUID().uuidString,
        attachments: [[String: Any]] = []
    ) async throws {
        var params: [String: Any] = [
            "sessionKey": sessionKey,
            "message": message,
            "idempotencyKey": idempotencyKey,
            "deliver": false,
        ]
        if !attachments.isEmpty {
            params["attachments"] = attachments
        }
        let chatFrame: [String: Any] = [
            "type": "req",
            "id": chatSendId,
            "method": "chat.send",
            "params": params,
        ]
        try await sendJSON(chatFrame, on: task)
    }

    private func waitForChatSendAccepted(on task: URLSessionWebSocketTask, chatSendId: String) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let json = try await receiveJSON(on: task, timeoutSeconds: min(remaining, 15))
            guard (json["type"] as? String) == "res", (json["id"] as? String) == chatSendId else { continue }
            if (json["ok"] as? Bool) == false {
                let error = json["error"] as? [String: Any]
                let message = (error?["message"] as? String) ?? (error?["code"] as? String) ?? "chat.send rejected"
                AppLog.error("chat.send audio rejected: \(message)")
                throw GatewayJobError.runFailed(message)
            }
            return
        }
        throw GatewayJobError.timedOut()
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
        jobLogId: String? = nil,
        sendStartedAt: Date = Date(),
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        var latestText = ""
        var lastProgress = ""
        var sawAssistantDelta = false
        var lastWSFrameAt: Date?
        var workingAt: Date?
        var runId: String?

        func emit(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != lastProgress else { return }
            lastProgress = trimmed
            if workingAt == nil, trimmed.localizedCaseInsensitiveContains("Working") {
                workingAt = Date()
            }
            onProgress(trimmed)
        }

        func diagnostics(source: String, backendErrorCode: String? = nil) -> GatewayJobDiagnostics {
            let now = Date()
            return GatewayJobDiagnostics(
                failureSource: source,
                elapsedSinceSend: now.timeIntervalSince(sendStartedAt),
                elapsedSinceLastWSFrame: lastWSFrameAt.map { now.timeIntervalSince($0) },
                elapsedSinceWorking: workingAt.map { now.timeIntervalSince($0) },
                runId: runId,
                wsCloseCode: String(describing: task.closeCode),
                backendErrorCode: backendErrorCode
            )
        }

        // No run cap: we wait as long as the agent keeps working. The only exit besides final/error is a dead socket,
        // detected when receiveJSON sees no frame at all within the stall window.
        while true {
            let json: [String: Any]
            do {
                json = try await receiveJSON(on: task, timeoutSeconds: stallTimeoutSeconds)
            } catch {
                let source = ((error as? GatewayJobError)?.isTimedOut == true) ? "stallTimeout" : "wsReceiveError"
                let failureDiagnostics = diagnostics(source: source, backendErrorCode: (error as? GatewayJobError)?.diagnostics?.backendErrorCode)
                if let jobLogId {
                    AppLog.error("[IPHONE][JOB \(jobLogId)] failed source=\(failureDiagnostics.failureSource) elapsedSinceSend=\(failureDiagnostics.elapsedSinceSend ?? -1) elapsedSinceLastWSFrame=\(failureDiagnostics.elapsedSinceLastWSFrame ?? -1) elapsedSinceWorking=\(failureDiagnostics.elapsedSinceWorking ?? -1) runId=\(failureDiagnostics.runId ?? "nil") wsCloseCode=\(failureDiagnostics.wsCloseCode ?? "nil") backendErrorCode=\(failureDiagnostics.backendErrorCode ?? "nil")")
                }
                AppLog.error("Job WS failed source=\(failureDiagnostics.failureSource) sessionKey=\(sessionKey) error=\(error.localizedDescription)")
                if source == "stallTimeout" {
                    throw GatewayJobError.timedOut(failureDiagnostics)
                }
                throw GatewayJobError.runFailed(error.localizedDescription, failureDiagnostics)
            }
            lastWSFrameAt = Date()

            let type = json["type"] as? String

            // Diagnostic: log every frame so we can see exactly what OpenClaw streams (event names + payload shape).
            if let jobLogId {
                AppLog.info("[IPHONE][JOB \(jobLogId)] ws frame received \(describeFrame(json, maxPayloadChars: 4000))")
            } else {
                AppLog.info("WSFRAME \(describeFrame(json))")
            }

            if type == "res", (json["id"] as? String) == chatSendId, (json["ok"] as? Bool) == false {
                let error = json["error"] as? [String: Any]
                let message = (error?["message"] as? String) ?? (error?["code"] as? String) ?? "chat.send rejected"
                let code = error?["code"] as? String
                let failureDiagnostics = diagnostics(source: "chatSendRejected", backendErrorCode: code ?? message)
                AppLog.error("chat.send rejected: \(message)")
                throw GatewayJobError.runFailed(message, failureDiagnostics)
            }

            if type == "res", (json["id"] as? String) == chatSendId,
               let payload = json["payload"] as? [String: Any],
               let startedRunId = payload["runId"] as? String,
               !startedRunId.isEmpty {
                runId = startedRunId
                if let jobLogId {
                    AppLog.info("[IPHONE][JOB \(jobLogId)] backend send accepted runId=\(startedRunId) chatSendId=\(chatSendId)")
                }
            }

            guard type == "event", let event = json["event"] as? String else { continue }
            let payload = json["payload"] as? [String: Any] ?? [:]

            if event == "session.message",
               eventSessionKey(payload) == nil || eventSessionKey(payload) == sessionKey,
               let finalText = extractAssistantText(from: payload),
               !finalText.isEmpty {
                if let jobLogId {
                    AppLog.info("[IPHONE][JOB \(jobLogId)] final reply parsed source=session.message length=\(finalText.count)")
                }
                AppLog.info("Resolved assistant reply from session.message length=\(finalText.count) sessionKey=\(sessionKey)")
                return finalText
            }

            if event == "agent",
               eventSessionKey(payload) == sessionKey,
               isCompletedAgentMessage(payload) {
                if let finalText = await latestAssistantTextFromHistory(sessionKey: sessionKey, jobLogId: jobLogId, source: "agentMessage.completed") {
                    return finalText
                }
                AppLog.info("agentMessage completed without assistant text yet; continuing to wait sessionKey=\(sessionKey)")
                continue
            }

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
                    if let historyText = await latestAssistantTextFromHistory(sessionKey: sessionKey, jobLogId: jobLogId, source: "chat.final.empty") {
                        return historyText
                    }
                    AppLog.info("chat final frame had no assistant text; continuing to wait sessionKey=\(sessionKey)")
                    continue
                }
                if let jobLogId {
                    AppLog.info("[IPHONE][JOB \(jobLogId)] final reply parsed source=chat.final length=\(finalText.count)")
                }
                return finalText
            case "error":
                let message = (payload["errorMessage"] as? String) ?? "Agent run failed."
                let code = (payload["errorCode"] as? String) ?? (payload["code"] as? String)
                let failureDiagnostics = diagnostics(source: "backendError", backendErrorCode: code ?? message)
                AppLog.error("chat run error: \(message)")
                throw GatewayJobError.runFailed(message, failureDiagnostics)
            default:
                continue
            }
        }
    }

    // ─── Ariadne's Thread [AT-0063] ─────────────────────
    // What: Treat empty completion frames as non-terminal and recover text from chat.history before failing.
    // Why:  OpenClaw can emit done/final frames before the assistant text is visible in that frame.
    // Date: 2026-06-08
    // Related: [AT-0027] GatewayJobClient.runAudioAttachment, [AT-0061] AppModel.recoverWatchAudioReplyFromHistory
    // ─────────────────────────────────────────────────────
    private func latestAssistantTextFromHistory(sessionKey: String, jobLogId: String?, source: String) async -> String? {
        do {
            let messages = try await fetchHistory(sessionKey: sessionKey)
            guard let finalText = messages.last(where: { !$0.isUser })?.text.trimmingCharacters(in: .whitespacesAndNewlines),
                  !finalText.isEmpty else {
                if let jobLogId {
                    AppLog.info("[IPHONE][JOB \(jobLogId)] final reply not ready source=\(source) historyAssistantText=no")
                }
                return nil
            }
            if let jobLogId {
                AppLog.info("[IPHONE][JOB \(jobLogId)] final reply parsed source=\(source).chat.history length=\(finalText.count)")
            }
            AppLog.info("Resolved assistant reply from chat.history source=\(source) length=\(finalText.count) sessionKey=\(sessionKey)")
            return finalText
        } catch {
            if let jobLogId {
                AppLog.error("[IPHONE][JOB \(jobLogId)] history recovery failed source=\(source) error=\(error.localizedDescription)")
            }
            AppLog.error("chat.history recovery failed source=\(source) sessionKey=\(sessionKey): \(error.localizedDescription)")
            return nil
        }
    }

    // ─── Ariadne's Thread [AT-0057] ─────────────────────
    // What: Keep iPhone relay diagnostics tied to the originating Watch job id.
    // Why:  Watch logs already prove file delivery; backend relay debugging needs searchable per-job iPhone logs.
    // Date: 2026-06-07
    // Related: [AT-0027] GatewayJobClient.runAudioAttachment, [AT-0025] app→AppModel.handleWatchAudioFile
    // ─────────────────────────────────────────────────────
    private func iphoneJobLogId(jobId: UUID?, fallback: String) -> String {
        let raw = jobId?.uuidString ?? fallback
        return String(raw.prefix(3))
    }

    /// Compact one-line description of a frame for diagnostics: type, event/id, and a truncated JSON of the payload.
    private func describeFrame(_ json: [String: Any], maxPayloadChars: Int = 600) -> String {
        let type = (json["type"] as? String) ?? "?"
        let event = (json["event"] as? String) ?? ""
        let id = (json["id"] as? String) ?? ""
        var payloadString = ""
        if let payload = json["payload"],
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let raw = String(data: data, encoding: .utf8) {
            payloadString = raw.count > maxPayloadChars ? String(raw.prefix(maxPayloadChars)) + "…" : raw
        }
        return "type=\(type) event=\(event) id=\(id) payload=\(payloadString)"
    }

    private func eventSessionKey(_ payload: [String: Any]) -> String? {
        if let key = payload["sessionKey"] as? String { return key }
        if let session = payload["session"] as? [String: Any], let key = session["key"] as? String { return key }
        return nil
    }

    private func isCompletedAgentMessage(_ payload: [String: Any]) -> Bool {
        guard let data = payload["data"] as? [String: Any] else { return false }
        let type = (data["type"] as? String) ?? (data["kind"] as? String)
        let phase = (data["phase"] as? String) ?? (data["status"] as? String)
        return type == "agentMessage" && phase == "completed"
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
        let source = (payload["message"] as? [String: Any]) ?? payload
        let role = (source["role"] as? String) ?? (source["author"] as? String)
        if let role, role.lowercased() != "assistant" { return nil }
        if let text = source["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if let contentText = source["content"] as? String, !contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return contentText
        }
        guard let content = source["content"] as? [[String: Any]] else {
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
                throw GatewayJobError.timedOut()
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
