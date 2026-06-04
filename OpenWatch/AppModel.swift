import AVFoundation
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var pairing = PairingSnapshot()
    @Published var jobs: [VoiceJob] = []
    @Published var activeJobId: UUID?
    /// Real sessions reported by the gateway (`sessions.list`). Source of truth for the iPhone sessions screen.
    @Published private(set) var gatewaySessions: [GatewaySessionRow] = []
    @Published private(set) var sessionsLoading = false
    /// Configured agents from the gateway (`agents.list`). Empty until first successful fetch.
    @Published private(set) var gatewayAgents: [GatewayAgentRow] = []
    @Published private(set) var agentsLoading = false
    @Published private(set) var isCreatingAgent = false
    /// Active agent id for filtering sessions and new voice/text runs (`agent:<id>:…` session keys).
    @Published private(set) var selectedAgentId: String = UserDefaults.standard.string(forKey: "selectedAgentId") ?? "main"
    @Published var errorBanner: String?
    /// Global "speak replies on Watch" switch. Persisted on iPhone and mirrored to the Watch on every sync.
    @Published var ttsEnabled: Bool = UserDefaults.standard.object(forKey: "ttsEnabled") as? Bool ?? true
    /// BCP-47 language used by the Watch to speak replies. Persisted on iPhone and mirrored to the Watch.
    @Published var ttsLanguage: String = UserDefaults.standard.string(forKey: "ttsLanguage") ?? "en-US"

    /// Every speech language available for the picker, shown with English display names (code, name), sorted by name.
    static let availableVoiceLanguages: [(code: String, name: String)] = {
        let codes = Set(AVSpeechSynthesisVoice.speechVoices().map { $0.language })
        let english = Locale(identifier: "en_US")
        return codes
            .map { code in (code: code, name: english.localizedString(forIdentifier: code) ?? code) }
            .sorted { $0.name < $1.name }
    }()
    /// Every voice command goes to this gateway session until the user explicitly starts a new one.
    @Published private(set) var currentSessionKey = "agent:main:main"

    private let speech = SpeechTranscriptionService()
    private let pairingClient: GatewayPairingClient
    private let jobClient = GatewayJobClient()
    private let watchBridge = WatchConnectivityPhoneService.shared
    private var lastWatchCommandKey: String?
    private var lastWatchCommandAt: Date?
    private var approvalPollTask: Task<Void, Never>?
    /// Last gateway session list (with recent history) pushed to the Watch, so we can re-push it on a Watch sync request.
    private var watchGatewaySessions: [WatchGatewaySession] = []
    /// Last usage summary pushed to the Watch, re-pushed on a Watch sync request.
    private var watchUsage: WatchUsage?
    /// Last agent list pushed to the Watch, re-pushed on a Watch sync request.
    private var watchAgentsPayload: [WatchGatewayAgent] = []
    /// Tracks the in-flight Watch enrichment so a new refresh supersedes an older one.
    private var watchEnrichTask: Task<Void, Never>?
    /// How many recent messages per session we mirror onto the Watch.
    private let watchHistoryLimit = 20

    private init() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        pairingClient = GatewayPairingClient(appVersion: version)
        if KeychainStore.isPaired, let url = KeychainStore.loadGatewayURL()?.absoluteString {
            pairing = PairingSnapshot(phase: .connected, gatewayURL: url, message: "Connected.")
        }
        watchBridge.publish(pairing: pairing, jobs: jobs, ttsEnabled: ttsEnabled, ttsLanguage: ttsLanguage)
        // Warm the voice catalog off the main thread so the language Picker never computes speechVoices() during render.
        Task.detached(priority: .utility) { _ = AppModel.availableVoiceLanguages }
    }

    /// Toggles global voice playback and immediately mirrors the new state to the Watch (which does the speaking).
    func setTTSEnabled(_ enabled: Bool) {
        ttsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "ttsEnabled")
        AppLog.info("Global TTS set enabled=\(enabled)")
        syncWatch()
    }

    /// Sets the speech language and mirrors it to the Watch.
    func setTTSLanguage(_ language: String) {
        ttsLanguage = language
        UserDefaults.standard.set(language, forKey: "ttsLanguage")
        AppLog.info("Global TTS language set=\(language)")
        syncWatch()
    }

    var isPaired: Bool {
        pairing.phase == .connected || KeychainStore.isPaired
    }

    /// Whether the Watch app is reachable right now (its app is active). The iPhone cannot launch the Watch app itself,
    /// so a remote "start listening" only takes effect while this is true.
    var isWatchReachable: Bool {
        watchBridge.isWatchReachable
    }

    /// Agents to show in the home list. Falls back to a single Main Actor row when the gateway returns none.
    var agentsForDisplay: [GatewayAgentRow] {
        if gatewayAgents.isEmpty {
            return [Self.fallbackMainActor]
        }
        return gatewayAgents
    }

    /// Agents for UI: **Main Actor** (`main`) is always first, then others alphabetically by display name.
    var sortedAgentsForDisplay: [GatewayAgentRow] {
        let list = agentsForDisplay
        let mains = list.filter { $0.id == "main" }
        let rest = list.filter { $0.id != "main" }.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        return mains + rest
    }

    /// Gateway sessions belonging to one agent (`agent:<id>:…`). Unknown keys are grouped under `main`.
    func gatewaySessions(forAgentId targetAgentId: String) -> [GatewaySessionRow] {
        gatewaySessions.filter { (agentId(fromSessionKey: $0.id) ?? "main") == targetAgentId }
    }

    /// Sessions for the currently selected agent (voice/text runs and Watch mirror).
    var filteredGatewaySessions: [GatewaySessionRow] {
        gatewaySessions(forAgentId: selectedAgentId)
    }

    /// True when the paired operator token includes `operator.admin` (required for `agents.create`).
    var canManageAgents: Bool {
        KeychainStore.loadOperatorScopes().contains("operator.admin")
    }

    private static let fallbackMainActor = GatewayAgentRow(
        id: "main",
        name: "Main Actor",
        emoji: "🎯",
        subtitle: "Default agent",
        modelLabel: nil,
        isDefault: true
    )

    /// Selects an agent and points new runs at that agent's default session key (`agent:<id>:main`).
    func selectAgent(_ agentId: String) {
        selectedAgentId = agentId
        UserDefaults.standard.set(agentId, forKey: "selectedAgentId")
        currentSessionKey = defaultSessionKey(forAgentId: agentId)
        pushAgentsToWatch()
        let rows = gatewaySessions(forAgentId: agentId)
        pushSessionListToWatch(rows: gatewaySessions)
        startWatchEnrichment(rows: rows)
        AppLog.info("Selected agent id=\(agentId) currentSessionKey=\(currentSessionKey) sessions=\(rows.count)")
    }

    /// Creates a new agent on the gateway via `agents.create`, then refreshes agents + sessions.
    func createAgent(name: String, emoji: String?) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorBanner = "Agent name is required."
            AppLog.error("createAgent blocked: empty name")
            return
        }
        guard canManageAgents else {
            AppLog.error("createAgent blocked: operator.admin not in scopes=\(KeychainStore.loadOperatorScopes().joined(separator: ","))")
            return
        }
        isCreatingAgent = true
        defer { isCreatingAgent = false }
        do {
            let agentId = try await jobClient.createAgent(
                name: trimmed,
                emoji: emoji,
                model: nil
            )
            AppLog.info("createAgent succeeded id=\(agentId) name=\(trimmed)")
            await refreshSessions()
            selectAgent(agentId)
        } catch {
            errorBanner = error.localizedDescription
            AppLog.error("createAgent failed: \(error.localizedDescription)")
        }
    }

    /// Maps gateway agents to the Watch transport type and pushes them to the Watch Agents page.
    private func pushAgentsToWatch() {
        let agents = sortedAgentsForDisplay.map {
            WatchGatewayAgent(
                id: $0.id,
                name: $0.name,
                emoji: $0.emoji,
                subtitle: $0.subtitle,
                modelLabel: $0.modelLabel,
                isDefault: $0.isDefault
            )
        }
        watchAgentsPayload = agents
        watchBridge.publishAgents(agents, selectedAgentId: selectedAgentId)
    }

    /// Loads agents + session index from the gateway. Called on home appear and on pull-to-refresh.
    func refreshSessions() async {
        guard isPaired else { return }
        sessionsLoading = true
        agentsLoading = true
        defer {
            sessionsLoading = false
            agentsLoading = false
        }
        do {
            let agentsResult = try await jobClient.listAgents()
            gatewayAgents = agentsResult.agents
            reconcileSelectedAgent(defaultId: agentsResult.defaultAgentId)
            pushAgentsToWatch()
            AppLog.info("Loaded \(agentsResult.agents.count) gateway agents defaultId=\(agentsResult.defaultAgentId)")
        } catch {
            AppLog.error("agents.list failed: \(error.localizedDescription)")
            // Keep previous gatewayAgents; UI falls back to Main Actor when empty.
        }
        do {
            let (rows, usage) = try await jobClient.listSessionsAndUsage()
            gatewaySessions = rows
            AppLog.info("Loaded \(rows.count) gateway sessions; usage totalTokens=\(usage.totalTokens) sessions=\(usage.sessionCount)")
            pushSessionListToWatch(rows: gatewaySessions)
            pushUsageToWatch(usage)
            startWatchEnrichment(rows: gatewaySessions(forAgentId: selectedAgentId))
        } catch {
            errorBanner = error.localizedDescription
            AppLog.error("refreshSessions failed: \(error.localizedDescription)")
        }
    }

    /// Parses `agent:<agentId>:…` from a gateway session key.
    func agentId(fromSessionKey sessionKey: String) -> String? {
        let parts = sessionKey.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "agent" else { return nil }
        let id = String(parts[1])
        return id.isEmpty ? nil : id
    }

    private func defaultSessionKey(forAgentId agentId: String) -> String {
        "agent:\(agentId):main"
    }

    private func reconcileSelectedAgent(defaultId: String) {
        let ids = Set(gatewayAgents.map(\.id))
        if !ids.contains(selectedAgentId) {
            let next = ids.contains(defaultId) ? defaultId : (gatewayAgents.first?.id ?? "main")
            AppLog.info("Reconciling selectedAgentId \(selectedAgentId) -> \(next)")
            selectAgent(next)
        }
    }

    /// Maps gateway usage to the Watch transport type and pushes it to the Watch's Usage page.
    private var configuredAgentCount: Int {
        gatewayAgents.isEmpty ? watchAgentsPayload.count : gatewayAgents.count
    }

    private func pushUsageToWatch(_ usage: GatewayUsage) {
        let watch = usageSnapshotForWatch(from: usage, agentCount: configuredAgentCount)
        watchUsage = watch
        AppLog.info("Pushing usage to Watch sessions=\(watch.sessionCount) agents=\(watch.agentCount) totalTokens=\(watch.totalTokens)")
        watchBridge.publishUsage(watch)
    }

    /// Rebuilds cached usage for Watch sync so agent count stays current after `agents.list`.
    private func usageSnapshotForWatch(from usage: GatewayUsage, agentCount: Int) -> WatchUsage {
        WatchUsage(
            sessionCount: usage.sessionCount,
            totalTokens: usage.totalTokens,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            totalMessages: usage.totalMessages,
            lastActivityAt: usage.lastActivityAt,
            model: usage.model,
            agentCount: agentCount
        )
    }

    private func republishCachedUsageToWatch() {
        guard let cached = watchUsage else { return }
        let updated = WatchUsage(
            sessionCount: cached.sessionCount,
            totalTokens: cached.totalTokens,
            inputTokens: cached.inputTokens,
            outputTokens: cached.outputTokens,
            totalMessages: cached.totalMessages,
            lastActivityAt: cached.lastActivityAt,
            model: cached.model,
            agentCount: configuredAgentCount
        )
        watchUsage = updated
        watchBridge.publishUsage(updated)
        AppLog.info("Republished usage to Watch agents=\(updated.agentCount) sessions=\(updated.sessionCount)")
    }

    /// Pushes the bare session list (no messages yet) to the Watch so pages render immediately.
    private func pushSessionListToWatch(rows: [GatewaySessionRow]) {
        let list = rows.map { WatchGatewaySession(id: $0.id, title: $0.title, preview: $0.preview, updatedAt: $0.updatedAt, messages: []) }
        watchGatewaySessions = list
        watchBridge.publishGatewaySessions(list)
    }

    /// Fetches recent history for each gateway session and re-pushes the enriched list to the Watch.
    private func startWatchEnrichment(rows: [GatewaySessionRow]) {
        watchEnrichTask?.cancel()
        let limit = watchHistoryLimit
        watchEnrichTask = Task { [weak self] in
            guard let self else { return }
            var built: [WatchGatewaySession] = []
            for row in rows {
                if Task.isCancelled { return }
                var recent: [WatchHistoryMessage] = []
                do {
                    let messages = try await self.jobClient.fetchHistory(sessionKey: row.id)
                    recent = messages.suffix(limit).map {
                        WatchHistoryMessage(id: $0.id, isUser: $0.isUser, text: String($0.text.prefix(500)))
                    }
                } catch {
                    AppLog.error("Watch enrich history failed sessionKey=\(row.id): \(error.localizedDescription)")
                }
                built.append(WatchGatewaySession(id: row.id, title: row.title, preview: row.preview, updatedAt: row.updatedAt, messages: recent))
            }
            if Task.isCancelled { return }
            await MainActor.run {
                self.watchGatewaySessions = built
                self.watchBridge.publishGatewaySessions(built)
                AppLog.info("Pushed \(built.count) gateway sessions with recent history to Watch")
            }
        }
    }

    /// Loads the real transcript for one session from the gateway.
    func history(for sessionKey: String) async -> [ChatHistoryMessage] {
        do {
            let messages = try await jobClient.fetchHistory(sessionKey: sessionKey)
            AppLog.info("Loaded \(messages.count) history messages for sessionKey=\(sessionKey)")
            return messages
        } catch {
            errorBanner = error.localizedDescription
            AppLog.error("history load failed sessionKey=\(sessionKey): \(error.localizedDescription)")
            return []
        }
    }

    /// Connects to any OpenClaw gateway: paste a full `openclaw qr` setup code, or enter gateway address + bootstrap token.
    func submitPairing(gatewayURL: String, setupCode: String) {
        Task {
            pairing.phase = .connecting
            pairing.message = "Connecting…"
            errorBanner = nil
            syncWatch()
            do {
                let payload = try SetupCodeDecoder.resolvePairingInput(
                    gatewayURLInput: gatewayURL,
                    setupCodeInput: setupCode
                )
                AppLog.info(
                    "submitPairing connecting host=\(payload.gatewayURL.host ?? "unknown") port=\(payload.gatewayURL.port ?? 0)"
                )
                let snapshot = try await pairingClient.connect(using: payload)
                pairing = snapshot
                SetupCodeDecoder.saveLastGatewayURL(payload.gatewayURL)
                AppLog.info("Pairing phase=\(snapshot.phase.rawValue) gatewayHost=\(payload.gatewayURL.host ?? "unknown")")
                if snapshot.phase == .waitingForApproval {
                    startApprovalPolling()
                } else {
                    stopApprovalPolling()
                }
            } catch {
                pairing.phase = .failed
                pairing.message = error.localizedDescription
                errorBanner = error.localizedDescription
                AppLog.error("Pairing failed: \(error.localizedDescription)")
            }
            syncWatch()
        }
    }

    func recheckApproval() {
        guard let url = KeychainStore.loadGatewayURL() else { return }
        let bootstrap = loadBootstrapFromKeychain()
        Task {
            pairing.phase = .connecting
            pairing.message = "Checking approval…"
            syncWatch()
            do {
                pairing = try await pairingClient.recheckApproval(gatewayURL: url, bootstrapToken: bootstrap)
                if pairing.phase == .connected {
                    stopApprovalPolling()
                }
            } catch {
                pairing.phase = .failed
                pairing.message = error.localizedDescription
                errorBanner = error.localizedDescription
            }
            syncWatch()
        }
    }

    func disconnect() {
        stopApprovalPolling()
        KeychainStore.clear()
        pairing = PairingSnapshot(phase: .needsSetupCode, message: "Enter a new setup code.")
        jobs = []
        gatewaySessions = []
        gatewayAgents = []
        watchEnrichTask?.cancel()
        watchGatewaySessions = []
        watchUsage = nil
        watchAgentsPayload = []
        activeJobId = nil
        watchBridge.publishGatewaySessions([])
        Task { await jobClient.closeReadSocket() }
        syncWatch(revokeGatewayPairing: true)
    }

    func handleWatchMessage(_ data: Data) async {
        guard let envelope = try? JSONDecoder().decode(WatchEnvelope.self, from: data) else {
            AppLog.error("Failed to decode watch envelope")
            return
        }
        let commandKey = "\(envelope.kind.rawValue)-\(envelope.jobId?.uuidString ?? "")"
        if let lastWatchCommandKey,
           lastWatchCommandKey == commandKey,
           let lastWatchCommandAt,
           Date().timeIntervalSince(lastWatchCommandAt) < 3 {
            AppLog.info("Skipping duplicate watch command key=\(commandKey)")
            return
        }
        lastWatchCommandKey = commandKey
        lastWatchCommandAt = Date()

        AppLog.info("handleWatchMessage kind=\(envelope.kind.rawValue)")
        switch envelope.kind {
        case .startListening:
            await startListeningFromWatch()
        case .stopAndSend:
            await stopAndSendFromWatch()
        case .submitTranscript:
            await relayTranscriptFromWatch(jobId: envelope.jobId, text: envelope.text)
        case .newSession:
            startNewSession()
        case .cancelJob:
            if let id = envelope.jobId {
                cancelJob(id: id)
            }
        case .selectAgent:
            let agentId = (envelope.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !agentId.isEmpty else {
                AppLog.error("selectAgent from Watch ignored: empty agent id")
                return
            }
            AppLog.info("Watch selected agent id=\(agentId)")
            selectAgent(agentId)
            pushSessionListToWatch(rows: gatewaySessions)
            startWatchEnrichment(rows: gatewaySessions(forAgentId: agentId))
        case .requestSync:
            AppLog.info("Watch requested sync; republishing pairing + jobs phase=\(pairing.phase.rawValue) keychainPaired=\(KeychainStore.isPaired)")
            syncWatch()
            // Mirror gateway sessions + usage too: re-push the cached values if we have them, otherwise fetch now.
            if !watchGatewaySessions.isEmpty {
                watchBridge.publishGatewaySessions(watchGatewaySessions)
                republishCachedUsageToWatch()
                if !watchAgentsPayload.isEmpty {
                    watchBridge.publishAgents(watchAgentsPayload, selectedAgentId: selectedAgentId)
                }
            } else if isPaired {
                Task { await refreshSessions() }
            }
        default:
            break
        }
    }

    /// Receives a voice recording captured on the Watch, transcribes it on iPhone, and runs it through the session the
    /// Watch chose (each Watch session has its own sessionKey).
    func handleWatchAudio(jobId: UUID, fileURL: URL, sessionKey: String) async {
        defer { try? FileManager.default.removeItem(at: fileURL) }

        guard isPaired else {
            errorBanner = "Pair on iPhone before using the watch."
            AppLog.error("handleWatchAudio blocked: not paired jobId=\(jobId)")
            return
        }

        let index: Int
        if let existing = jobs.firstIndex(where: { $0.id == jobId }) {
            index = existing
            jobs[index].status = .sending
            jobs[index].statusDetail = "Transcribing…"
        } else {
            let job = VoiceJob(id: jobId, status: .sending, statusDetail: "Transcribing…")
            jobs.insert(job, at: 0)
            index = 0
        }
        activeJobId = jobId
        AppLog.info("handleWatchAudio transcribing jobId=\(jobId) sessionKey=\(sessionKey)")
        syncWatch(job: jobs[index])

        do {
            let transcript = try await speech.transcribeFile(at: fileURL)
            guard !transcript.isEmpty else {
                throw NSError(domain: "OpenWatch", code: 4, userInfo: [NSLocalizedDescriptionKey: "No speech detected."])
            }
            guard let runningIndex = jobs.firstIndex(where: { $0.id == jobId }) else { return }
            jobs[runningIndex].transcript = transcript
            jobs[runningIndex].status = .running
            jobs[runningIndex].statusDetail = "Working…"
            AppLog.info("handleWatchAudio transcript ready jobId=\(jobId) length=\(transcript.count)")
            syncWatch(job: jobs[runningIndex])

            let reply = try await jobClient.runCommand(
                transcript: transcript,
                sessionKey: sessionKey,
                onProgress: makeProgressHandler(jobId: jobId)
            )
            guard let doneIndex = jobs.firstIndex(where: { $0.id == jobId }) else { return }
            jobs[doneIndex].resultText = reply
            jobs[doneIndex].status = .done
            jobs[doneIndex].statusDetail = nil
            jobs[doneIndex].completedAt = Date()
            if activeJobId == jobId { activeJobId = nil }
            AppLog.info("handleWatchAudio done jobId=\(jobId) replyLength=\(reply.count)")
            syncWatch(job: jobs[doneIndex])
        } catch {
            guard let failIndex = jobs.firstIndex(where: { $0.id == jobId }) else { return }
            jobs[failIndex].status = .failed
            jobs[failIndex].errorMessage = error.localizedDescription
            jobs[failIndex].statusDetail = nil
            jobs[failIndex].completedAt = Date()
            if activeJobId == jobId { activeJobId = nil }
            errorBanner = error.localizedDescription
            AppLog.error("handleWatchAudio failed jobId=\(jobId): \(error.localizedDescription)")
            syncWatch(job: jobs[failIndex])
        }
    }

    /// Sends a TYPED text message from the iPhone straight into a specific gateway session via chat.send.
    /// This is text only (not voice) — voice still originates on the Watch. Returns when the agent reply arrives so the
    /// caller can reload the transcript.
    func sendText(_ text: String, to sessionKey: String) async {
        guard isPaired else {
            errorBanner = "Pair on iPhone before sending messages."
            AppLog.error("sendText blocked: not paired sessionKey=\(sessionKey)")
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            AppLog.error("sendText ignored empty text sessionKey=\(sessionKey)")
            return
        }

        let job = VoiceJob(status: .running, transcript: trimmed, statusDetail: "Working…")
        jobs.insert(job, at: 0)
        activeJobId = job.id
        AppLog.info("sendText running jobId=\(job.id) sessionKey=\(sessionKey) length=\(trimmed.count)")
        syncWatch(job: job)

        do {
            let reply = try await jobClient.runCommand(
                transcript: trimmed,
                sessionKey: sessionKey,
                onProgress: makeProgressHandler(jobId: job.id)
            )
            if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[idx].resultText = reply
                jobs[idx].status = .done
                jobs[idx].statusDetail = nil
                jobs[idx].completedAt = Date()
                if activeJobId == job.id { activeJobId = nil }
                syncWatch(job: jobs[idx])
            }
            AppLog.info("sendText done jobId=\(job.id) replyLength=\(reply.count)")
        } catch {
            if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[idx].status = .failed
                jobs[idx].errorMessage = error.localizedDescription
                jobs[idx].statusDetail = nil
                jobs[idx].completedAt = Date()
                if activeJobId == job.id { activeJobId = nil }
                syncWatch(job: jobs[idx])
            }
            errorBanner = error.localizedDescription
            AppLog.error("sendText failed jobId=\(job.id) sessionKey=\(sessionKey): \(error.localizedDescription)")
        }
    }

    /// Starts a brand-new chat session: a fresh sessionKey. Past sessions stay as their own cards (history is not wiped).
    func startNewSession() {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        currentSessionKey = "agent:\(selectedAgentId):\(token)"
        activeJobId = nil
        AppLog.info("Started new session sessionKey=\(currentSessionKey) agentId=\(selectedAgentId)")
        syncWatch()
    }

    func republishToWatch(reason: String) {
        AppLog.info("Republishing state to Watch reason=\(reason) phase=\(pairing.phase.rawValue)")
        syncWatch()
        guard isPaired else { return }
        if !watchGatewaySessions.isEmpty {
            watchBridge.publishGatewaySessions(watchGatewaySessions)
            republishCachedUsageToWatch()
            if !watchAgentsPayload.isEmpty {
                watchBridge.publishAgents(watchAgentsPayload, selectedAgentId: selectedAgentId)
            }
            AppLog.info("Republish included gateway sessions=\(watchGatewaySessions.count) agents=\(watchAgentsPayload.count)")
        } else {
            AppLog.info("Republish: no cached gateway sessions; refreshing from gateway")
            Task { await refreshSessions() }
        }
    }

    /// Active voice job on the iPhone (mirrored from Watch commands), if any.
    var activeVoiceJob: VoiceJob? {
        guard let id = activeJobId else { return nil }
        return jobs.first { $0.id == id }
    }

    /// True when a voice job is in progress for the given agent (after `startListen(forAgentId:)`).
    func isVoiceJobActive(forAgentId agentId: String) -> Bool {
        guard selectedAgentId == agentId, let job = activeVoiceJob else { return false }
        switch job.status {
        case .listening, .sending, .running:
            return true
        case .idle, .done, .failed, .cancelled:
            return false
        }
    }

    /// "Tap to listen" under an agent: selects that agent, then remote-starts recording on the Watch (Watch app must be on screen).
    func startListen(forAgentId agentId: String) {
        guard isPaired else {
            errorBanner = "Pair on iPhone before using the watch."
            AppLog.error("startListen blocked: not paired agentId=\(agentId)")
            return
        }
        selectAgent(agentId)
        guard isWatchReachable else {
            errorBanner = "Open OpenWatch on your Watch to record."
            AppLog.error("startListen blocked: Watch not reachable agentId=\(agentId)")
            return
        }
        AppLog.info("iPhone Tap to listen agentId=\(agentId) -> startListening on Watch")
        watchBridge.sendCommandToWatch(WatchEnvelope(kind: .startListening, text: agentId))
    }

    /// Legacy entry point: starts listen for the currently selected agent.
    func toggleListenOnPhone() {
        startListen(forAgentId: selectedAgentId)
    }

    private func startListeningFromWatch() async {
        guard isPaired else {
            errorBanner = "Pair on iPhone before using the watch."
            return
        }
        let allowed = await speech.ensurePermissions()
        guard allowed else {
            errorBanner = "Microphone and speech recognition permissions are required. Grant them once in OpenWatch on iPhone."
            syncWatch()
            return
        }
        do {
            try speech.startListening()
            let job = VoiceJob(status: .listening, statusDetail: "Listening…")
            jobs.insert(job, at: 0)
            activeJobId = job.id
            syncWatch(job: job)
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    private func stopAndSendFromWatch() async {
        guard let jobId = activeJobId, let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[index].status = .sending
        jobs[index].statusDetail = "Sending…"
        syncWatch(job: jobs[index])
        do {
            let transcript = try await speech.stopAndTranscribe()
            guard !transcript.isEmpty else {
                throw NSError(domain: "OpenWatch", code: 4, userInfo: [NSLocalizedDescriptionKey: "No speech detected."])
            }
            jobs[index].transcript = transcript
            jobs[index].status = .running
            jobs[index].statusDetail = "Working…"
            syncWatch(job: jobs[index])

            let reply = try await jobClient.runCommand(
                transcript: transcript,
                sessionKey: currentSessionKey,
                onProgress: makeProgressHandler(jobId: jobId)
            )
            jobs[index].resultText = reply
            jobs[index].status = .done
            jobs[index].statusDetail = nil
            jobs[index].completedAt = Date()
            activeJobId = nil
            syncWatch(job: jobs[index])
        } catch {
            jobs[index].status = .failed
            jobs[index].errorMessage = error.localizedDescription
            jobs[index].statusDetail = nil
            jobs[index].completedAt = Date()
            activeJobId = nil
            errorBanner = error.localizedDescription
            syncWatch(job: jobs[index])
        }
    }

    /// Relays a transcript that was captured ON THE WATCH to the gateway. The iPhone microphone is never used here.
    private func relayTranscriptFromWatch(jobId: UUID?, text: String?) async {
        guard isPaired else {
            errorBanner = "Pair on iPhone before using the watch."
            AppLog.error("relayTranscriptFromWatch blocked: not paired")
            syncWatch()
            return
        }
        let transcript = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            AppLog.error("relayTranscriptFromWatch received empty transcript jobId=\(jobId?.uuidString ?? "nil")")
            return
        }

        let id = jobId ?? UUID()
        let index: Int
        if let existing = jobs.firstIndex(where: { $0.id == id }) {
            index = existing
            jobs[index].transcript = transcript
            jobs[index].status = .running
            jobs[index].statusDetail = "Working…"
        } else {
            let job = VoiceJob(id: id, status: .running, transcript: transcript, statusDetail: "Working…")
            jobs.insert(job, at: 0)
            index = 0
        }
        activeJobId = id
        AppLog.info("relayTranscriptFromWatch running jobId=\(id) length=\(transcript.count)")
        syncWatch(job: jobs[index])

        do {
            let reply = try await jobClient.runCommand(
                transcript: transcript,
                sessionKey: currentSessionKey,
                onProgress: makeProgressHandler(jobId: id)
            )
            guard let liveIndex = jobs.firstIndex(where: { $0.id == id }) else { return }
            jobs[liveIndex].resultText = reply
            jobs[liveIndex].status = .done
            jobs[liveIndex].statusDetail = nil
            jobs[liveIndex].completedAt = Date()
            if activeJobId == id { activeJobId = nil }
            AppLog.info("relayTranscriptFromWatch done jobId=\(id) replyLength=\(reply.count)")
            syncWatch(job: jobs[liveIndex])
        } catch {
            guard let liveIndex = jobs.firstIndex(where: { $0.id == id }) else { return }
            jobs[liveIndex].status = .failed
            jobs[liveIndex].errorMessage = error.localizedDescription
            jobs[liveIndex].statusDetail = nil
            jobs[liveIndex].completedAt = Date()
            if activeJobId == id { activeJobId = nil }
            errorBanner = error.localizedDescription
            AppLog.error("relayTranscriptFromWatch failed jobId=\(id): \(error.localizedDescription)")
            syncWatch(job: jobs[liveIndex])
        }
    }

    private func cancelJob(id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        speech.cancel()
        jobs[index].status = .cancelled
        jobs[index].completedAt = Date()
        if activeJobId == id { activeJobId = nil }
        syncWatch(job: jobs[index])
    }

    private func syncWatch(job: VoiceJob? = nil, revokeGatewayPairing: Bool = false) {
        watchBridge.publish(
            pairing: pairing,
            jobs: jobs,
            ttsEnabled: ttsEnabled,
            ttsLanguage: ttsLanguage,
            revokeGatewayPairing: revokeGatewayPairing
        )
        if let job { watchBridge.publish(job: job) }
    }

    /// Builds a progress sink for a run: every streamed step from the gateway becomes the job's live `statusDetail`
    /// and is pushed to the Watch so both screens show what OpenClaw is currently doing.
    private func makeProgressHandler(jobId: UUID) -> @Sendable (String) -> Void {
        { [weak self] step in
            Task { @MainActor in
                guard let self else { return }
                guard let idx = self.jobs.firstIndex(where: { $0.id == jobId }) else { return }
                guard self.jobs[idx].status == .running || self.jobs[idx].status == .sending else { return }
                self.jobs[idx].statusDetail = step
                AppLog.info("Run progress jobId=\(jobId) step=\(step)")
                self.syncWatch(job: self.jobs[idx])
            }
        }
    }

    private func loadBootstrapFromKeychain() -> String? {
        KeychainStore.loadBootstrapToken()
    }

    private func startApprovalPolling() {
        stopApprovalPolling()
        AppLog.info("Starting automatic approval polling")
        approvalPollTask = Task { [weak self] in
            guard let self else { return }
            for attempt in 1 ... 30 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard self.pairing.phase == .waitingForApproval else {
                        self.stopApprovalPolling()
                        return
                    }
                    AppLog.info("Automatic approval poll attempt=\(attempt)")
                    self.recheckApproval()
                }
            }
        }
    }

    private func stopApprovalPolling() {
        approvalPollTask?.cancel()
        approvalPollTask = nil
    }
}
