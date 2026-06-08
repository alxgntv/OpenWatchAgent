import Foundation

// ─── Ariadne's Thread [AT-0048] ─────────────────────
// What: Carry the Gateway session key with Watch voice jobs.
// Why:  Watch must attach restored iPhone job snapshots to the right gateway page after app relaunch.
// Date: 2026-06-07
// Related: [AT-0046] app→AppModel.resumePendingAudioJobs
// ─────────────────────────────────────────────────────
nonisolated public struct VoiceJob: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var status: JobStatus
    public var transcript: String?
    public var resultText: String?
    public var errorMessage: String?
    public var statusDetail: String?
    public var gatewayRunId: String?
    public var gatewaySessionKey: String?
    // ─── Ariadne's Thread [AT-0064] ─────────────────────
    // What: Carry iPhone relay failure diagnostics with each failed Watch job.
    // Why:  The Watch must show whether a failure came from timeout, backend error, WS close, or stale delivery.
    // Date: 2026-06-08
    // Related: [AT-0063] app→GatewayJobClient.latestAssistantTextFromHistory
    // ─────────────────────────────────────────────────────
    public var failureSource: String?
    public var elapsedSinceSend: Double?
    public var elapsedSinceLastWSFrame: Double?
    public var elapsedSinceWorking: Double?
    public var wsCloseCode: String?
    public var backendErrorCode: String?
    public let agentId: String
    public let createdAt: Date
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        status: JobStatus = .idle,
        transcript: String? = nil,
        resultText: String? = nil,
        errorMessage: String? = nil,
        statusDetail: String? = nil,
        gatewayRunId: String? = nil,
        gatewaySessionKey: String? = nil,
        failureSource: String? = nil,
        elapsedSinceSend: Double? = nil,
        elapsedSinceLastWSFrame: Double? = nil,
        elapsedSinceWorking: Double? = nil,
        wsCloseCode: String? = nil,
        backendErrorCode: String? = nil,
        agentId: String = "main",
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.status = status
        self.transcript = transcript
        self.resultText = resultText
        self.errorMessage = errorMessage
        self.statusDetail = statusDetail
        self.gatewayRunId = gatewayRunId
        self.gatewaySessionKey = gatewaySessionKey
        self.failureSource = failureSource
        self.elapsedSinceSend = elapsedSinceSend
        self.elapsedSinceLastWSFrame = elapsedSinceLastWSFrame
        self.elapsedSinceWorking = elapsedSinceWorking
        self.wsCloseCode = wsCloseCode
        self.backendErrorCode = backendErrorCode
        self.agentId = agentId
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}
