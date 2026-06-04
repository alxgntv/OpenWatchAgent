import Foundation

nonisolated public struct VoiceJob: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var status: JobStatus
    public var transcript: String?
    public var resultText: String?
    public var errorMessage: String?
    public var statusDetail: String?
    public var gatewayRunId: String?
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
        self.agentId = agentId
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}
