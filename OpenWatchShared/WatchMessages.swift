import Foundation

nonisolated public enum OpenWatchVoiceSettings {
    public static let defaultLaunchGreetingPhrase = "Hello Sir"
    public static let defaultLaunchGreetingLanguage = "en-US"
    public static let launchGreetingPhraseDefaultsKey = "launchGreetingPhrase"
    public static let launchGreetingLanguageDefaultsKey = "launchGreetingLanguage"
    public static let launchGreetingVoiceIdentifierDefaultsKey = "launchGreetingVoiceIdentifier"
}

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
    /// Legacy iPhone → Watch gateway session payload. Watch UI no longer uses this as an active sync path.
    case gatewaySessions
    /// iPhone → Watch: aggregate usage (session count, tokens, model) for the Watch's Usage page.
    case usage
    /// iPhone → Watch: configured gateway agents for the Watch's Agents page.
    case agents
    /// Watch → iPhone: user picked an agent on the Watch (`text` carries the agent id).
    case selectAgent
    /// iPhone → Watch: authenticated gateway WSS probe result.
    case gatewayProbe
    /// Watch → iPhone: request only gateway sessions that are missing on Watch.
    case requestGatewaySessions
    /// Legacy Watch → iPhone request for the agent navigation model. Current flow is iPhone startup-owned.
    case requestAgentIndexDelta
    /// iPhone → Watch: configured gateway agent index delta.
    case agentIndexDelta
    /// iPhone → Watch: gateway session index delta without messages.
    case sessionIndexDelta
    /// iPhone → Watch: messages for one gateway session.
    case sessionMessagesDelta
    /// Watch → iPhone: request missing session index rows for the selected agent.
    case requestSessionIndexDelta
    /// Watch → iPhone: request missing messages for one session.
    case requestSessionMessagesDelta
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

public typealias WatchAgentRow = WatchGatewayAgent
public typealias WatchMessageRow = WatchHistoryMessage

// ─── Ariadne's Thread [AT-0097] ─────────────────────
// What: Split Watch sync payloads into agent index, session index, and session messages deltas.
// Why:  Watch SwiftUI lists must receive stable row snapshots, while session messages update only detail state.
// Date: 2026-06-08
// Related: [AT-0094] watch→WatchAppModel.gatewayMessagesBySessionKey, [AT-0096] watch→WatchAppModel.mergeGatewayMessages
// ─────────────────────────────────────────────────────
nonisolated public struct WatchSessionRow: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let preview: String?
    public let updatedAt: Date?

    public init(id: String, title: String, preview: String?, updatedAt: Date?) {
        self.id = id
        self.title = title
        self.preview = preview
        self.updatedAt = updatedAt
    }

    public init(session: WatchGatewaySession) {
        self.init(id: session.id, title: session.title, preview: session.preview, updatedAt: session.updatedAt)
    }
}

nonisolated public struct WatchAgentIndexDelta: Codable, Sendable, Equatable {
    public let agents: [WatchAgentRow]
    public let selectedAgentId: String?
    public let isFullSnapshot: Bool?

    public init(agents: [WatchAgentRow], selectedAgentId: String?, isFullSnapshot: Bool? = nil) {
        self.agents = agents
        self.selectedAgentId = selectedAgentId
        self.isFullSnapshot = isFullSnapshot
    }
}

nonisolated public struct WatchSessionIndexDelta: Codable, Sendable, Equatable {
    public let selectedAgentId: String?
    public let sessions: [WatchSessionRow]

    public init(selectedAgentId: String?, sessions: [WatchSessionRow]) {
        self.selectedAgentId = selectedAgentId
        self.sessions = sessions
    }
}

nonisolated public struct WatchSessionMessagesDelta: Codable, Sendable, Equatable {
    public let sessionKey: String
    public let messages: [WatchMessageRow]

    public init(sessionKey: String, messages: [WatchMessageRow]) {
        self.sessionKey = sessionKey
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
    /// Spoken phrase when the Watch app opens (e.g. "Hello Sir"). nil means "unchanged / unknown".
    public let launchGreetingPhrase: String?
    /// BCP-47 language for the launch greeting TTS. nil means "unchanged / unknown".
    public let launchGreetingLanguage: String?
    /// AVSpeechSynthesisVoice identifier for the launch greeting. nil/empty means language default on Watch.
    public let launchGreetingVoiceIdentifier: String?
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
    /// iPhone proof that the gateway WSS endpoint completed connect.challenge -> connect -> hello-ok.
    public let gatewayReachable: Bool?
    /// Human-readable gateway probe proof/error detail for Watch logs and button gating.
    public let gatewayProbeDetail: String?
    /// iPhone → Watch: gateway operator token for direct Watch WSS. nil means unchanged.
    public let gatewayOperatorToken: String?
    /// iPhone → Watch: operator scopes for direct Watch WSS. nil means unchanged.
    public let gatewayOperatorScopes: [String]?
    /// iPhone → Watch: configured gateway agent index delta. nil means unchanged.
    public let agentIndexDelta: WatchAgentIndexDelta?
    /// iPhone → Watch: gateway session index delta without messages. nil means unchanged.
    public let sessionIndexDelta: WatchSessionIndexDelta?
    /// iPhone → Watch: messages for one gateway session. nil means unchanged.
    public let sessionMessagesDelta: WatchSessionMessagesDelta?
    /// Watch → iPhone: one session whose messages should be returned.
    public let requestedSessionKey: String?
    // ─── Ariadne's Thread [AT-0083] ─────────────────────
    // What: Add Watch-known gateway agent ids to the sync envelope.
    // Why:  iPhone must return only agents missing from the Watch cache instead of sending a full live replacement.
    // Date: 2026-06-08
    // Related: [AT-0070] watch→WatchConnectivityWatchService.requestMissingGatewaySessions, [AT-0071] app→AppModel.publishMissingGatewaySessionsToWatch
    // ─────────────────────────────────────────────────────
    /// Watch → iPhone: gateway agent ids already stored on Watch.
    public let knownGatewayAgentIds: [String]?
    /// Watch → iPhone: gateway session ids already stored on Watch.
    public let knownGatewaySessionIds: [String]?
    /// Watch → iPhone: message ids already stored per gateway session on Watch.
    public let knownGatewayMessageIdsBySession: [String: [String]]?
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
        launchGreetingPhrase: String? = nil,
        launchGreetingLanguage: String? = nil,
        launchGreetingVoiceIdentifier: String? = nil,
        gatewaySessions: [WatchGatewaySession]? = nil,
        replaceGatewaySessions: Bool? = nil,
        usage: WatchUsage? = nil,
        gatewayAgents: [WatchGatewayAgent]? = nil,
        selectedAgentId: String? = nil,
        revokeGatewayPairing: Bool? = nil,
        gatewayReachable: Bool? = nil,
        gatewayProbeDetail: String? = nil,
        gatewayOperatorToken: String? = nil,
        gatewayOperatorScopes: [String]? = nil,
        agentIndexDelta: WatchAgentIndexDelta? = nil,
        sessionIndexDelta: WatchSessionIndexDelta? = nil,
        sessionMessagesDelta: WatchSessionMessagesDelta? = nil,
        requestedSessionKey: String? = nil,
        knownGatewayAgentIds: [String]? = nil,
        knownGatewaySessionIds: [String]? = nil,
        knownGatewayMessageIdsBySession: [String: [String]]? = nil
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
        self.launchGreetingPhrase = launchGreetingPhrase
        self.launchGreetingLanguage = launchGreetingLanguage
        self.launchGreetingVoiceIdentifier = launchGreetingVoiceIdentifier
        self.gatewaySessions = gatewaySessions
        self.replaceGatewaySessions = replaceGatewaySessions
        self.usage = usage
        self.gatewayAgents = gatewayAgents
        self.selectedAgentId = selectedAgentId
        self.revokeGatewayPairing = revokeGatewayPairing
        self.gatewayReachable = gatewayReachable
        self.gatewayProbeDetail = gatewayProbeDetail
        self.gatewayOperatorToken = gatewayOperatorToken
        self.gatewayOperatorScopes = gatewayOperatorScopes
        self.agentIndexDelta = agentIndexDelta
        self.sessionIndexDelta = sessionIndexDelta
        self.sessionMessagesDelta = sessionMessagesDelta
        self.requestedSessionKey = requestedSessionKey
        self.knownGatewayAgentIds = knownGatewayAgentIds
        self.knownGatewaySessionIds = knownGatewaySessionIds
        self.knownGatewayMessageIdsBySession = knownGatewayMessageIdsBySession
    }
}
