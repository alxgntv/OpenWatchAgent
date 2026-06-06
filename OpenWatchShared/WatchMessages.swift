import Foundation

nonisolated public enum WatchMessageKind: String, Codable, Sendable {
    case pairingSnapshot
    case jobsSnapshot
    case jobUpdated
    case startListening
    case stopAndSend
    case cancelJob
    case requestSync
    /// Watch → iPhone: the Watch recognized speech locally and sends the final transcript text for relay to the gateway.
    case submitTranscript
    /// Either direction: start a brand-new chat session (a fresh sessionKey). Voice keeps going to the current session otherwise.
    case newSession
    /// iPhone → Watch: the real gateway session index (with recent history) for the Watch's horizontal session pages.
    case gatewaySessions
    /// iPhone → Watch: aggregate usage (session count, tokens, model) for the Watch's Usage page.
    case usage
    /// iPhone → Watch: configured gateway agents for the Watch's Agents page.
    case agents
    /// Watch → iPhone: user picked an agent on the Watch (`text` carries the agent id).
    case selectAgent
}

/// Aggregate usage derived from the gateway's `sessions.list`, mirrored to the Watch's Usage page.
nonisolated public struct WatchUsage: Codable, Sendable, Equatable {
    public let sessionCount: Int
    public let totalTokens: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let totalMessages: Int
    public let lastActivityAt: Date?
    public let model: String?
    /// Configured agents from `agents.list` (not part of `sessions.list` usage payload).
    public let agentCount: Int

    /// Average tokens per session, derived (0 when there are no sessions).
    public var avgTokensPerSession: Int {
        sessionCount > 0 ? totalTokens / sessionCount : 0
    }

    public init(
        sessionCount: Int,
        totalTokens: Int,
        inputTokens: Int,
        outputTokens: Int,
        totalMessages: Int,
        lastActivityAt: Date?,
        model: String?,
        agentCount: Int = 0
    ) {
        self.sessionCount = sessionCount
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalMessages = totalMessages
        self.lastActivityAt = lastActivityAt
        self.model = model
        self.agentCount = agentCount
    }
}

/// One configured gateway agent mirrored to the Watch Agents page.
nonisolated public struct WatchGatewayAgent: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let emoji: String?
    public let subtitle: String?
    public let modelLabel: String?
    public let isDefault: Bool

    public init(
        id: String,
        name: String,
        emoji: String?,
        subtitle: String?,
        modelLabel: String?,
        isDefault: Bool
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.subtitle = subtitle
        self.modelLabel = modelLabel
        self.isDefault = isDefault
    }
}

/// One recent transcript message of a gateway session, pushed from the iPhone to the Watch (oldest-first).
nonisolated public struct WatchHistoryMessage: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let isUser: Bool
    public let text: String

    public init(id: String, isUser: Bool, text: String) {
        self.id = id
        self.isUser = isUser
        self.text = text
    }
}

/// One real gateway session mirrored onto the Watch as a horizontal page: identity + a slice of recent history.
nonisolated public struct WatchGatewaySession: Codable, Sendable, Identifiable, Equatable {
    public let id: String              // sessionKey (e.g. "agent:main:...")
    public let title: String
    public let preview: String?
    public let updatedAt: Date?        // last activity time, shown compactly as the page title
    public let messages: [WatchHistoryMessage]   // recent slice, oldest-first

    public init(id: String, title: String, preview: String?, updatedAt: Date?, messages: [WatchHistoryMessage]) {
        self.id = id
        self.title = title
        self.preview = preview
        self.updatedAt = updatedAt
        self.messages = messages
    }
}

// ─── Ariadne's Thread [AT-0007] ─────────────────────
// What: Add Watch record-button haptic options to the shared envelope model.
// Why:  The iPhone settings screen controls which native Watch haptic plays when recording starts/stops.
// Date: 2026-06-05
// Related: AppModel.setHapticType, WatchAppModel.playRecordHaptic
// ─────────────────────────────────────────────────────
nonisolated public enum WatchHapticType: String, Codable, Sendable, CaseIterable, Identifiable {
    case off
    case notification
    case directionUp
    case directionDown
    case success
    case failure
    case retry
    case start
    case stop
    case click

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .notification: return "Notification"
        case .directionUp: return "Direction Up"
        case .directionDown: return "Direction Down"
        case .success: return "Success"
        case .failure: return "Failure"
        case .retry: return "Retry"
        case .start: return "Start"
        case .stop: return "Stop"
        case .click: return "Click"
        }
    }
}

nonisolated public struct WatchEnvelope: Codable, Sendable {
    public let kind: WatchMessageKind
    public let jobId: UUID?
    public let pairing: PairingSnapshot?
    public let job: VoiceJob?
    public let jobs: [VoiceJob]?
    public let text: String?
    /// Global "speak replies on Watch" switch, controlled from the iPhone app. nil means "unchanged / unknown".
    public let ttsEnabled: Bool?
    /// BCP-47 language code the Watch should use to speak replies (e.g. "en-US"). nil means "unchanged / unknown".
    public let ttsLanguage: String?
    /// Watch haptic played on record start/stop. nil means "unchanged / unknown".
    public let hapticType: String?
    /// Watch speech rate multiplier for spoken replies. nil means "unchanged / unknown".
    public let ttsRate: Double?
    /// Real gateway session index (with recent history) for the Watch's horizontal pages. nil means "unchanged / unknown".
    public let gatewaySessions: [WatchGatewaySession]?
    /// true/nil = replace Watch gateway sessions; false = merge only changed/missing sessions.
    public let replaceGatewaySessions: Bool?
    /// Aggregate usage for the Watch's Usage page. nil means "unchanged / unknown".
    public let usage: WatchUsage?
    /// Configured agents for the Watch's Agents page. nil means "unchanged / unknown".
    public let gatewayAgents: [WatchGatewayAgent]?
    /// Active agent id on the iPhone (filters sessions). nil means "unchanged / unknown".
    public let selectedAgentId: String?
    /// When true, the iPhone explicitly disconnected (Disconnect button). The Watch may clear its sticky pairing cache.
    /// Any other envelope must not unpair the Watch even if pairing.phase is needsSetupCode.
    public let revokeGatewayPairing: Bool?
    public init(
        kind: WatchMessageKind,
        jobId: UUID? = nil,
        pairing: PairingSnapshot? = nil,
        job: VoiceJob? = nil,
        jobs: [VoiceJob]? = nil,
        text: String? = nil,
        ttsEnabled: Bool? = nil,
        ttsLanguage: String? = nil,
        hapticType: String? = nil,
        ttsRate: Double? = nil,
        gatewaySessions: [WatchGatewaySession]? = nil,
        replaceGatewaySessions: Bool? = nil,
        usage: WatchUsage? = nil,
        gatewayAgents: [WatchGatewayAgent]? = nil,
        selectedAgentId: String? = nil,
        revokeGatewayPairing: Bool? = nil
    ) {
        self.kind = kind
        self.jobId = jobId
        self.pairing = pairing
        self.job = job
        self.jobs = jobs
        self.text = text
        self.ttsEnabled = ttsEnabled
        self.ttsLanguage = ttsLanguage
        self.hapticType = hapticType
        self.ttsRate = ttsRate
        self.gatewaySessions = gatewaySessions
        self.replaceGatewaySessions = replaceGatewaySessions
        self.usage = usage
        self.gatewayAgents = gatewayAgents
        self.selectedAgentId = selectedAgentId
        self.revokeGatewayPairing = revokeGatewayPairing
    }
}
