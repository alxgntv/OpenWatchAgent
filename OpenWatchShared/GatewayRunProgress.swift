import Foundation

// ─── Ariadne's Thread [AT-0171] ─────────────────────
// What: Parse gateway run progress steps and format Watch Speak button labels.
// Why:  The Speak button should stream live agent/tool/assistant steps truncated to 12 chars.
// Date: 2026-06-12
// Related: [AT-0027] GatewayJobClient.waitForReply, WatchHomeView.speakButton
// ─────────────────────────────────────────────────────
enum GatewayRunProgress {
    static let speakButtonMaxLength = 12

    static func speakButtonLabel(statusDetail: String?, status: JobStatus) -> String {
        let trimmed = statusDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = status == .sending ? "Sending…" : "Working…"
        guard let trimmed, !trimmed.isEmpty else { return fallback }
        if trimmed.count <= speakButtonMaxLength { return trimmed }
        return String(trimmed.prefix(speakButtonMaxLength))
    }

    /// Builds a short human-readable line from a streamed gateway session/agent event.
    static func progressStep(event: String, payload: [String: Any]) -> String? {
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
            if let stream = payload["stream"] as? String {
                let data = payload["data"] as? [String: Any] ?? [:]
                if stream == "assistant", let text = data["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
                if stream == "tool", let name = data["name"] as? String, !name.isEmpty {
                    if let phase = data["phase"] as? String, !phase.isEmpty {
                        return "Tool: \(name) (\(phase))"
                    }
                    return "Tool: \(name)"
                }
                if stream == "lifecycle", let phase = data["phase"] as? String, !phase.isEmpty {
                    return phase
                }
            }
            if let status = firstString(["status", "state", "phase"]) { return "Agent: \(status)" }
            return "Working…"
        case "session.message":
            if let role = firstString(["role"]), role != "assistant" { return nil }
            return nil
        default:
            return nil
        }
    }

    static func eventSessionKey(_ payload: [String: Any]) -> String? {
        if let key = payload["sessionKey"] as? String { return key }
        if let session = payload["session"] as? [String: Any], let key = session["key"] as? String { return key }
        return nil
    }
}
