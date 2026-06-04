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
    /// Real gateway session index (with recent history) for the Watch's horizontal pages. nil means "unchanged / unknown".
    public let gatewaySessions: [WatchGatewaySession]?

    public init(
        kind: WatchMessageKind,
        jobId: UUID? = nil,
        pairing: PairingSnapshot? = nil,
        job: VoiceJob? = nil,
        jobs: [VoiceJob]? = nil,
        text: String? = nil,
        ttsEnabled: Bool? = nil,
        ttsLanguage: String? = nil,
        gatewaySessions: [WatchGatewaySession]? = nil
    ) {
        self.kind = kind
        self.jobId = jobId
        self.pairing = pairing
        self.job = job
        self.jobs = jobs
        self.text = text
        self.ttsEnabled = ttsEnabled
        self.ttsLanguage = ttsLanguage
        self.gatewaySessions = gatewaySessions
    }
}
