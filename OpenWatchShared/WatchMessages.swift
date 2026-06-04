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
}

nonisolated public struct WatchEnvelope: Codable, Sendable {
    public let kind: WatchMessageKind
    public let jobId: UUID?
    public let pairing: PairingSnapshot?
    public let job: VoiceJob?
    public let jobs: [VoiceJob]?
    public let text: String?

    public init(
        kind: WatchMessageKind,
        jobId: UUID? = nil,
        pairing: PairingSnapshot? = nil,
        job: VoiceJob? = nil,
        jobs: [VoiceJob]? = nil,
        text: String? = nil
    ) {
        self.kind = kind
        self.jobId = jobId
        self.pairing = pairing
        self.job = job
        self.jobs = jobs
        self.text = text
    }
}
