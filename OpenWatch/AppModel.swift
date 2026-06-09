import AVFoundation
import Combine
import Foundation
import Speech
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
    /// BCP-47 language used for both Apple Speech input and Watch spoken replies. Defaults to the user's device language.
    @Published var voiceLanguage: String = UserDefaults.standard.string(forKey: "voiceLanguage") ?? AppModel.defaultVoiceLanguage()
    /// Haptic feedback the Watch plays when record starts/stops. Persisted on iPhone and mirrored to the Watch.
    @Published var hapticType: WatchHapticType = WatchHapticType(rawValue: UserDefaults.standard.string(forKey: "hapticType") ?? "") ?? .start
    /// Speech rate multiplier the Watch uses to speak replies. Persisted on iPhone and mirrored to the Watch.
    @Published var ttsRate: Double = UserDefaults.standard.object(forKey: "ttsRate") as? Double ?? 1.0

    /// Selectable Watch speech rate multipliers.
    static let availableTTSRates: [Double] = [1.0, 1.10, 1.25, 1.30, 1.40, 1.50, 1.75, 2.0]

    /// Languages supported by both Apple Speech recognition and AVSpeechSynthesizer output.
    static let availableVoiceLanguages: [(code: String, name: String)] = {
        let english = Locale(identifier: "en_US")
        let recognitionCodes = Set(SFSpeechRecognizer.supportedLocales().map(\.identifier))
        let synthesisCodes = Set(AVSpeechSynthesisVoice.speechVoices().map(\.language))
        return recognitionCodes
            .intersection(synthesisCodes)
            .map { locale in
                let name = english.localizedString(forIdentifier: locale) ?? locale
                return (code: locale, name: name)
            }
            .sorted { $0.name < $1.name }
    }()

    private static func defaultVoiceLanguage() -> String {
        let supportedCodes = availableVoiceLanguages.map(\.code)
        let candidates = Locale.preferredLanguages + [Locale.autoupdatingCurrent.identifier]
        for candidate in candidates {
            if let supported = matchingSupportedSpeechLocale(for: candidate, supportedCodes: supportedCodes) {
                return supported
            }
        }
        return SFSpeechRecognizer()?.locale.identifier ?? "en-US"
    }

    private static func matchingSupportedSpeechLocale(for candidate: String, supportedCodes: [String]) -> String? {
        let normalizedCandidate = normalizedLocaleIdentifier(candidate)
        if let exact = supportedCodes.first(where: { normalizedLocaleIdentifier($0) == normalizedCandidate }) {
            return exact
        }
        let languageCode = normalizedCandidate.split(separator: "-").first.map(String.init) ?? normalizedCandidate
        return supportedCodes.first {
            normalizedLocaleIdentifier($0).split(separator: "-").first.map(String.init) == languageCode
        }
    }

    private static func normalizedLocaleIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

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
    /// Already enriched sessions keyed by sessionKey. Used to avoid refetching/resending the same session messages.
    private var watchEnrichedSessionCache: [String: WatchGatewaySession] = [:]
    private var pendingAudioJobs: [PendingAudioJob] = []
    private var pendingResumeTask: Task<Void, Never>?
    private let pendingAudioJobsKey = "openwatch.pendingAudioJobs.v1"
    private let watchMessageTextLimit = 500

    // ─── Ariadne's Thread [AT-0045] ─────────────────────
    // What: Persist accepted Watch audio jobs until a later reconcile fetches their final gateway reply.
    // Why:  Locked/background iPhone cannot reliably wait on one long WSS run after chat.send is accepted.
    // Date: 2026-06-07
    // Related: [AT-0044] app→GatewayJobClient.submitAudioAttachment
    // ─────────────────────────────────────────────────────
    private struct PendingAudioJob: Codable, Equatable {
        let watchJobId: UUID
        let sessionKey: String
        let chatSendId: String
        let idempotencyKey: String
        let acceptedAt: Date
        let historyBaselineAssistantCount: Int
        var lastCheckedAt: Date?
    }

    private init() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        pairingClient = GatewayPairingClient(appVersion: version)
        pendingAudioJobs = Self.loadPendingAudioJobs(key: pendingAudioJobsKey)
        if KeychainStore.isPaired, let url = KeychainStore.loadGatewayURL()?.absoluteString {
            pairing = PairingSnapshot(phase: .connected, gatewayURL: url, message: "Connected.")
        }
        watchBridge.publish(
            pairing: pairing,
            jobs: jobs,
            ttsEnabled: ttsEnabled,
            ttsLanguage: voiceLanguage,
            hapticType: hapticType.rawValue,
            ttsRate: ttsRate
        )
        _ = AppModel.availableVoiceLanguages
    }

    private static func loadPendingAudioJobs(key: String) -> [PendingAudioJob] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([PendingAudioJob].self, from: data)
        } catch {
            AppLog.error("Failed to decode pending audio jobs: \(error.localizedDescription)")
            return []
        }
    }

    private func savePendingAudioJobs() {
        do {
            let data = try JSONEncoder().encode(pendingAudioJobs)
            UserDefaults.standard.set(data, forKey: pendingAudioJobsKey)
            AppLog.info("Saved pending audio jobs count=\(pendingAudioJobs.count)")
        } catch {
            AppLog.error("Failed to encode pending audio jobs: \(error.localizedDescription)")
        }
    }

    /// Toggles global voice playback and immediately mirrors the new state to the Watch (which does the speaking).
    func setTTSEnabled(_ enabled: Bool) {
        ttsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "ttsEnabled")
        AppLog.info("Global TTS set enabled=\(enabled)")
        syncWatch()
    }

    // ─── Ariadne's Thread [AT-0006] ─────────────────────
    // What: Persist one voice language selected on iPhone.
    // Why:  Input recognition and spoken replies must use the same user-selected language,
    //       defaulting to the device language on first launch.
    // Date: 2026-06-05
    // Related: [AT-0005] SpeechTranscriptionService speechRecognizer locale removal
    // ─────────────────────────────────────────────────────
    func setVoiceLanguage(_ language: String) {
        voiceLanguage = language
        UserDefaults.standard.set(language, forKey: "voiceLanguage")
        AppLog.info("Voice language set=\(language)")
        syncWatch()
    }

    // ─── Ariadne's Thread [AT-0008] ─────────────────────
    // What: Persist and mirror Watch haptic and TTS-rate controls from iPhone settings.
    // Why:  The iPhone app owns global voice preferences, and the Watch must use the selected
    //       native haptic on record-button start/stop plus the selected speech-rate multiplier.
    // Date: 2026-06-05
    // Related: [AT-0007] WatchEnvelope haptic/rate fields, WatchAppModel.applyHapticType
    // ─────────────────────────────────────────────────────
    func setHapticType(_ haptic: WatchHapticType) {
        hapticType = haptic
        UserDefaults.standard.set(haptic.rawValue, forKey: "hapticType")
        AppLog.info("Watch haptic type set=\(haptic.rawValue)")
        syncWatch()
    }

    func setTTSRate(_ rate: Double) {
        ttsRate = rate
        UserDefaults.standard.set(rate, forKey: "ttsRate")
        AppLog.info("Watch TTS rate set=\(rate)")
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
        cacheWatchAgentsPayload()
        publishSelectedAgentToWatch()
        let rows = gatewaySessions(forAgentId: agentId)
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

    // ─── Ariadne's Thread [AT-0089] ─────────────────────
    // What: Cache iPhone-side Watch agent payloads without pushing full lists to Watch.
    // Why:  Watch owns its visible cache and requests missing agents by known ids; iPhone may only push selectedAgentId directly.
    // Date: 2026-06-08
    // Related: [AT-0087] AppModel.publishMissingGatewayAgentsToWatch, [AT-0085] watch→WatchAppModel.mergeGatewayAgentDelta
    // ─────────────────────────────────────────────────────
    private func cacheWatchAgentsPayload() {
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
        AppLog.info("Cached Watch agents payload count=\(agents.count) selectedAgentId=\(selectedAgentId); waiting for Watch missing-agent request")
    }

    private func publishSelectedAgentToWatch() {
        watchBridge.publishAgents([], selectedAgentId: selectedAgentId, force: true)
        AppLog.info("Pushed selectedAgentId only to Watch selectedAgentId=\(selectedAgentId)")
    }

    // ─── Ariadne's Thread [AT-0087] ─────────────────────
    // What: Publish only gateway agents missing from the Watch cache.
    // Why:  Watch owns its visible agents list and sends known agent ids so iPhone can return deltas only.
    // Date: 2026-06-08
    // Related: [AT-0083] shared→WatchEnvelope.knownGatewayAgentIds, [AT-0085] watch→WatchAppModel.mergeGatewayAgentDelta
    // ─────────────────────────────────────────────────────
    private func publishMissingGatewayAgentsToWatch(knownIds: Set<String>) async {
        guard isPaired else { return }
        do {
            let agentsResult = try await jobClient.listAgents()
            gatewayAgents = agentsResult.agents
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
            let missing = agents.filter { !knownIds.contains($0.id) }
            watchBridge.publishAgents(missing, selectedAgentId: selectedAgentId, force: true)
            AppLog.info("Watch missing agents sent delta=\(missing.count) knownAgents=\(knownIds.count) totalAgents=\(agents.count) selectedAgentId=\(selectedAgentId)")
        } catch {
            let missing = watchAgentsPayload.filter { !knownIds.contains($0.id) }
            if !missing.isEmpty {
                watchBridge.publishAgents(missing, selectedAgentId: selectedAgentId, force: true)
            }
            AppLog.error("Watch missing agents request failed knownAgents=\(knownIds.count); cachedDelta=\(missing.count): \(error.localizedDescription)")
        }
    }

    private func publishAgentNavigationModelToWatch() async {
        guard isPaired else { return }
        do {
            let agentsResult = try await jobClient.listAgents()
            gatewayAgents = agentsResult.agents
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
            watchBridge.publishAgents(agents, selectedAgentId: selectedAgentId, force: true, fullSnapshot: true)
            AppLog.info("Watch agent navigation model sent fullSnapshot agents=\(agents.count) selectedAgentId=\(selectedAgentId)")
        } catch {
            watchBridge.publishAgents(watchAgentsPayload, selectedAgentId: selectedAgentId, force: true, fullSnapshot: true)
            AppLog.error("Watch agent navigation model request failed; cachedAgents=\(watchAgentsPayload.count): \(error.localizedDescription)")
        }
    }

    /// Loads agents + session index from the gateway. Called on home appear and on pull-to-refresh.
    func refreshSessions(showErrors: Bool = true) async {
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
            cacheWatchAgentsPayload()
            AppLog.info("Loaded \(agentsResult.agents.count) gateway agents defaultId=\(agentsResult.defaultAgentId)")
        } catch {
            AppLog.error("agents.list failed: \(error.localizedDescription)")
            // Keep previous gatewayAgents; UI falls back to Main Actor when empty.
        }
        do {
            let (rows, usage) = try await jobClient.listSessionsAndUsage()
            gatewaySessions = rows
            AppLog.info("Loaded \(rows.count) gateway sessions; usage totalTokens=\(usage.totalTokens) sessions=\(usage.sessionCount)")
            pushUsageToWatch(usage)
        } catch {
            handleRefreshSessionsError(error, showErrors: showErrors)
        }
    }

    // ─── Ariadne's Thread [AT-0010] ─────────────────────
    // What: Suppress read-only refresh alerts while a voice job is running.
    // Why:  Reopening the iPhone app during Watch "Working…" starts sessions.list/chat.history refreshes;
    //       those can time out independently of the active chat.send socket and should not look like the job failed.
    // Date: 2026-06-05
    // Related: AppModel.refreshSessions, GatewayJobClient.readRPC
    // ─────────────────────────────────────────────────────
    private func handleRefreshSessionsError(_ error: Error, showErrors: Bool) {
        let message = error.localizedDescription
        if !showErrors || activeVoiceJob != nil {
            AppLog.error("refreshSessions failed silently showErrors=\(showErrors) activeVoiceJob=\(activeVoiceJob?.id.uuidString ?? "nil"): \(message)")
            return
        }
        errorBanner = message
        AppLog.error("refreshSessions failed: \(message)")
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

    private func republishCachedUsageToWatch(force: Bool = false) {
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
        watchBridge.publishUsage(updated, force: force)
        AppLog.info("Republished usage to Watch agents=\(updated.agentCount) sessions=\(updated.sessionCount) force=\(force)")
    }

    private func bareWatchGatewaySession(from row: GatewaySessionRow) -> WatchGatewaySession {
        WatchGatewaySession(id: row.id, title: row.title, preview: row.preview, updatedAt: row.updatedAt, messages: [])
    }

    private func cachedEnrichedWatchSession(for row: GatewaySessionRow) -> WatchGatewaySession? {
        guard let cached = watchEnrichedSessionCache[row.id],
              cached.title == row.title,
              cached.preview == row.preview,
              cached.updatedAt == row.updatedAt,
              !cached.messages.isEmpty else {
            return nil
        }
        return cached
    }

    // ─── Ariadne's Thread [AT-0029] ─────────────────────
    // What: Push only missing or changed sessions and session messages to Watch.
    // Why:  Session/message data can be large; once Watch has a snapshot, repeat refreshes should not resend it.
    // Date: 2026-06-06
    // Related: [AT-0028] app→WatchConnectivityPhoneService queueSnapshotToWatch, app→WatchAppModel mergeGatewaySessionDelta
    // ─────────────────────────────────────────────────────
    private func mergeAndPublishWatchGatewaySessions(_ incoming: [WatchGatewaySession], replaceIfEmpty: Bool) {
        guard !incoming.isEmpty || replaceIfEmpty else {
            AppLog.info("Watch gateway sessions publish skipped: empty delta")
            return
        }
        var previous: [String: WatchGatewaySession] = [:]
        for session in watchGatewaySessions {
            previous[session.id] = session
        }
        var mergedById = previous
        for session in incoming {
            mergedById[session.id] = session
            if !session.messages.isEmpty {
                watchEnrichedSessionCache[session.id] = session
            }
        }
        let ordered = gatewaySessions.map { row in
            mergedById[row.id] ?? bareWatchGatewaySession(from: row)
        }
        let shouldReplace = replaceIfEmpty && watchGatewaySessions.isEmpty
        let delta = shouldReplace ? ordered : ordered.filter { previous[$0.id] != $0 }
        watchGatewaySessions = ordered
        guard !delta.isEmpty || shouldReplace else {
            AppLog.info("Watch gateway sessions publish skipped: no changed or missing sessions")
            return
        }
        watchBridge.publishGatewaySessions(delta, replace: shouldReplace)
        AppLog.info("Watch gateway sessions published delta=\(delta.count) total=\(ordered.count) replace=\(shouldReplace)")
    }

    /// Pushes the bare session list (no messages yet) to the Watch so pages render immediately.
    private func pushSessionListToWatch(rows: [GatewaySessionRow]) {
        let list = rows.map { row in
            bareWatchGatewaySession(from: row)
        }
        if rows.isEmpty {
            watchGatewaySessions = []
            watchBridge.publishGatewaySessions([], replace: true, force: true)
            AppLog.info("Pushed empty gateway session list to Watch")
            return
        }
        mergeAndPublishWatchGatewaySessions(list, replaceIfEmpty: true)
    }

    /// Fetches recent history for each gateway session and re-pushes the enriched list to the Watch.
    private func startWatchEnrichment(rows: [GatewaySessionRow]) {
        watchEnrichTask?.cancel()
        watchEnrichTask = Task { [weak self] in
            guard let self else { return }
            var built: [WatchGatewaySession] = []
            for row in rows {
                if Task.isCancelled { return }
                if await MainActor.run(body: { self.cachedEnrichedWatchSession(for: row) != nil }) {
                    AppLog.info("Watch enrich skipped cached sessionKey=\(row.id)")
                    continue
                }
                var recent: [WatchHistoryMessage] = []
                do {
                    let messages = try await self.jobClient.fetchHistory(sessionKey: row.id)
                    recent = messages.map {
                        WatchHistoryMessage(id: $0.id, isUser: $0.isUser, text: String($0.text.prefix(self.watchMessageTextLimit)))
                    }
                } catch {
                    AppLog.error("Watch enrich history failed sessionKey=\(row.id): \(error.localizedDescription)")
                }
                built.append(WatchGatewaySession(id: row.id, title: row.title, preview: row.preview, updatedAt: row.updatedAt, messages: recent))
            }
            if Task.isCancelled { return }
            await MainActor.run {
                self.mergeAndPublishWatchGatewaySessions(built, replaceIfEmpty: false)
                AppLog.info("Pushed \(built.count) changed gateway sessions with recent history to Watch")
            }
        }
    }

    // ─── Ariadne's Thread [AT-0105] ─────────────────────
    // What: Answer Watch screen requests with separate session index and session messages deltas.
    // Why:  Session detail message updates must never publish or mutate the Watch sessions list rows.
    // Date: 2026-06-08
    // Related: [AT-0104] app→WatchConnectivityPhoneService.publishSessionMessagesDelta, [AT-0099] watch→WatchAppModel.applySessionMessagesDelta
    // ─────────────────────────────────────────────────────
    private func publishMissingGatewaySessionsToWatch(knownIds: Set<String>, knownMessageIdsBySession: [String: [String]], requestedAgentId: String?) async {
        guard isPaired else { return }
        let targetAgentId = (requestedAgentId?.isEmpty == false ? requestedAgentId : selectedAgentId) ?? selectedAgentId
        do {
            let (rows, _) = try await jobClient.listSessionsAndUsage()
            gatewaySessions = rows
            // ─── Ariadne's Thread [AT-0113] ─────────────────────
            // What: Scope Watch missing-session responses to the requested agent.
            // Why:  Pull-to-refresh on Watch Sessions must not import rows from other agents.
            // Date: 2026-06-09
            // Related: [AT-0110] watch→WatchAppModel.refreshSessionsForCurrentAgent
            // ─────────────────────────────────────────────────────
            let agentRows = rows.filter { (agentId(fromSessionKey: $0.id) ?? "main") == targetAgentId }
            // ─── Ariadne's Thread [AT-0074] ─────────────────────
            // What: Load message deltas only for session ids explicitly requested by Watch.
            // Why:  The Sessions list opens often; fetching every cached session history at once overloaded watchOS during merge/cache.
            // Date: 2026-06-08
            // Related: [AT-0069] watch→WatchAppModel.requestMissingGatewaySessionsForSessionScreen, [AT-0079] watch→WatchAppModel.requestMissingGatewayMessagesForSession
            // ─────────────────────────────────────────────────────
            let missingRows = agentRows.filter { !knownIds.contains($0.id) }

            let bare = missingRows.map { row in
                cachedEnrichedWatchSession(for: row) ?? bareWatchGatewaySession(from: row)
            }
            if !bare.isEmpty {
                watchBridge.publishSessionIndexDelta(
                    WatchSessionIndexDelta(
                        selectedAgentId: targetAgentId,
                        sessions: bare.map { WatchSessionRow(session: $0) }
                    ),
                    force: true
                )
                AppLog.info("Watch missing sessions sent bare delta count=\(bare.count) knownCount=\(knownIds.count) agentId=\(targetAgentId)")
            }

            var sentEnrichedCount = 0
            let requestedMessageSessionIds = Set(knownMessageIdsBySession.keys)
            let requestedMessageRows = agentRows.filter { requestedMessageSessionIds.contains($0.id) }
            for row in requestedMessageRows {
                let knownMessageIds = Set(knownMessageIdsBySession[row.id] ?? [])
                if let cached = cachedEnrichedWatchSession(for: row) {
                    let missingMessages = cached.messages.filter { !knownMessageIds.contains($0.id) }
                    watchBridge.publishSessionMessagesDelta(
                        WatchSessionMessagesDelta(sessionKey: row.id, messages: missingMessages),
                        force: true
                    )
                    sentEnrichedCount += 1
                    AppLog.info("Watch missing session messages sent cached delta sessionKey=\(row.id) messages=\(missingMessages.count)")
                    continue
                }
                do {
                    let messages = try await jobClient.fetchHistory(sessionKey: row.id)
                    let allMessages = messages.map {
                        WatchHistoryMessage(id: $0.id, isUser: $0.isUser, text: String($0.text.prefix(watchMessageTextLimit)))
                    }
                    watchEnrichedSessionCache[row.id] = WatchGatewaySession(id: row.id, title: row.title, preview: row.preview, updatedAt: row.updatedAt, messages: allMessages)
                    let missingMessages = messages
                        .filter { !knownMessageIds.contains($0.id) }
                        .map {
                            WatchHistoryMessage(id: $0.id, isUser: $0.isUser, text: String($0.text.prefix(watchMessageTextLimit)))
                        }
                    watchBridge.publishSessionMessagesDelta(
                        WatchSessionMessagesDelta(sessionKey: row.id, messages: missingMessages),
                        force: true
                    )
                    sentEnrichedCount += 1
                    AppLog.info("Watch missing session messages sent fetched delta sessionKey=\(row.id) messages=\(missingMessages.count)")
                } catch {
                    AppLog.error("Watch missing session history failed sessionKey=\(row.id): \(error.localizedDescription)")
                }
            }
            guard sentEnrichedCount > 0 || !bare.isEmpty else {
                if let requestedSessionKey = knownMessageIdsBySession.keys.first {
                    watchBridge.publishSessionMessagesDelta(
                        WatchSessionMessagesDelta(sessionKey: requestedSessionKey, messages: []),
                        force: true
                    )
                } else {
                    watchBridge.publishSessionIndexDelta(
                        WatchSessionIndexDelta(selectedAgentId: targetAgentId, sessions: []),
                        force: true
                    )
                }
                AppLog.info("Watch missing sessions/messages request: nothing missing knownSessions=\(knownIds.count) knownMessageSessions=\(knownMessageIdsBySession.count) agentId=\(targetAgentId) agentTotal=\(agentRows.count) total=\(rows.count)")
                return
            }
            AppLog.info("Watch missing sessions/messages sent enriched deltas count=\(sentEnrichedCount) bareCount=\(bare.count) agentId=\(targetAgentId) agentTotal=\(agentRows.count) total=\(rows.count)")
        } catch {
            if let requestedSessionKey = knownMessageIdsBySession.keys.first {
                watchBridge.publishSessionMessagesDelta(
                    WatchSessionMessagesDelta(sessionKey: requestedSessionKey, messages: []),
                    force: true
                )
            } else {
                watchBridge.publishSessionIndexDelta(
                    WatchSessionIndexDelta(selectedAgentId: targetAgentId, sessions: []),
                    force: true
                )
            }
            AppLog.error("Watch missing sessions request failed knownCount=\(knownIds.count) agentId=\(targetAgentId): \(error.localizedDescription)")
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
        watchEnrichedSessionCache = [:]
        watchUsage = nil
        watchAgentsPayload = []
        activeJobId = nil
        watchBridge.resetSessionMessageAgentUsageDeliveryCache()
        watchBridge.publishGatewaySessions([], replace: true, force: true)
        watchBridge.publishUsage(WatchUsage(sessionCount: 0, totalTokens: 0, inputTokens: 0, outputTokens: 0, totalMessages: 0, lastActivityAt: nil, model: nil, agentCount: 0), force: true)
        watchBridge.publishAgents([], selectedAgentId: "main", force: true)
        Task { await jobClient.closeReadSocket() }
        syncWatch(revokeGatewayPairing: true)
    }

    func handleWatchMessage(_ data: Data) async {
        guard let envelope = try? JSONDecoder().decode(WatchEnvelope.self, from: data) else {
            AppLog.error("Failed to decode watch envelope")
            return
        }
        let commandKey = watchCommandKey(for: envelope)
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
        case .requestGatewaySessions:
            await publishMissingGatewayAgentsToWatch(knownIds: Set(envelope.knownGatewayAgentIds ?? []))
            await publishMissingGatewaySessionsToWatch(
                knownIds: Set(envelope.knownGatewaySessionIds ?? []),
                knownMessageIdsBySession: envelope.knownGatewayMessageIdsBySession ?? [:],
                requestedAgentId: envelope.selectedAgentId
            )
        case .requestAgentIndexDelta:
            await publishAgentNavigationModelToWatch()
        case .requestSessionIndexDelta:
            await publishMissingGatewayAgentsToWatch(knownIds: Set(envelope.knownGatewayAgentIds ?? []))
            await publishMissingGatewaySessionsToWatch(
                knownIds: Set(envelope.knownGatewaySessionIds ?? []),
                knownMessageIdsBySession: [:],
                requestedAgentId: envelope.selectedAgentId
            )
        case .requestSessionMessagesDelta:
            let requestedKey = envelope.requestedSessionKey
                ?? envelope.knownGatewayMessageIdsBySession?.keys.first
            guard let requestedKey, !requestedKey.isEmpty else {
                AppLog.error("requestSessionMessagesDelta ignored: missing sessionKey")
                return
            }
            let knownMessageIds = envelope.knownGatewayMessageIdsBySession?[requestedKey] ?? []
            await publishMissingGatewaySessionsToWatch(
                knownIds: Set(envelope.knownGatewaySessionIds ?? []),
                knownMessageIdsBySession: [requestedKey: knownMessageIds],
                requestedAgentId: envelope.selectedAgentId
            )
        case .requestSync:
            restoreGatewayURLFromWatchRequest(envelope.pairing)
            let activeWatchJobs = envelope.jobs ?? []
            // ─── Ariadne's Thread [AT-0066] ─────────────────────
            // What: Treat Watch requestSync as an explicit short poll for accepted async audio jobs.
            // Why:  Watch drives job status checks every few seconds; iPhone opens only short backend requests.
            // Date: 2026-06-08
            // Related: [AT-0065] AppModel.handleWatchAudioFile, [AT-0046] AppModel.resumePendingAudioJobs
            // ─────────────────────────────────────────────────────
            await resumePendingAudioJobs(reason: "watch-request-sync")
            await reconcileActiveWatchJobsFromHistory(activeWatchJobs)
            AppLog.info("Watch requested sync; republishing pairing + jobs phase=\(pairing.phase.rawValue) keychainPaired=\(KeychainStore.isPaired)")
            syncWatch()
            if !activeWatchJobs.isEmpty {
                AppLog.info("Watch requestSync handled as active job poll only count=\(activeWatchJobs.count)")
                return
            }
            Task { await publishGatewayProbeToWatch(reason: "watch-request-sync") }
            await publishMissingGatewayAgentsToWatch(knownIds: Set(envelope.knownGatewayAgentIds ?? []))
            if envelope.knownGatewaySessionIds != nil || envelope.knownGatewayMessageIdsBySession != nil {
                await publishMissingGatewaySessionsToWatch(
                    knownIds: Set(envelope.knownGatewaySessionIds ?? []),
                    knownMessageIdsBySession: envelope.knownGatewayMessageIdsBySession ?? [:],
                    requestedAgentId: envelope.selectedAgentId
                )
            } else {
                AppLog.info("Watch requestSync skipped sessions/messages delta; session data is screen-driven")
            }
            republishCachedUsageToWatch(force: true)
        default:
            break
        }
    }

    // ─── Ariadne's Thread [AT-0088] ─────────────────────
    // What: Include Watch cache fingerprints in request deduplication keys.
    // Why:  Session-list and per-session message delta requests share one kind but must not cancel each other.
    // Date: 2026-06-08
    // Related: [AT-0084] watch→WatchConnectivityWatchService.requestMissingGatewaySessions, [AT-0079] watch→WatchAppModel.requestMissingGatewayMessagesForSession
    // ─────────────────────────────────────────────────────
    private func watchCommandKey(for envelope: WatchEnvelope) -> String {
        switch envelope.kind {
        case .requestGatewaySessions, .requestAgentIndexDelta, .requestSessionIndexDelta, .requestSessionMessagesDelta, .requestSync:
            let knownAgents = envelope.knownGatewayAgentIds?.count ?? 0
            let knownSessions = envelope.knownGatewaySessionIds?.count ?? 0
            let messageFingerprint = (envelope.knownGatewayMessageIdsBySession ?? [:])
                .keys
                .sorted()
                .map { key in "\(key):\((envelope.knownGatewayMessageIdsBySession ?? [:])[key]?.count ?? 0)" }
                .joined(separator: "|")
            let jobs = (envelope.jobs ?? []).map { $0.id.uuidString }.sorted().joined(separator: ",")
            return "\(envelope.kind.rawValue)-agents=\(knownAgents)-sessions=\(knownSessions)-messages=\(messageFingerprint)-requested=\(envelope.requestedSessionKey ?? "")-jobs=\(jobs)-selected=\(envelope.selectedAgentId ?? "")"
        default:
            return "\(envelope.kind.rawValue)-\(envelope.jobId?.uuidString ?? "")"
        }
    }

    // ─── Ariadne's Thread [AT-0050] ─────────────────────
    // What: Close active Watch jobs from Gateway history during requestSync.
    // Why:  If iPhone is reinstalled/relaunched after the server answered, in-memory jobs are gone but Watch still knows jobId/sessionKey.
    // Date: 2026-06-07
    // Related: [AT-0048] shared→VoiceJob.gatewaySessionKey, [AT-0049] watch→WatchAppModel.upsert
    // ─────────────────────────────────────────────────────
    private func reconcileActiveWatchJobsFromHistory(_ watchJobs: [VoiceJob]?) async {
        guard let watchJobs, !watchJobs.isEmpty else { return }
        AppLog.info("Reconciling active Watch jobs from history count=\(watchJobs.count)")
        for watchJob in watchJobs where !watchJob.status.isTerminal {
            guard let sessionKey = watchJob.gatewaySessionKey, !sessionKey.isEmpty else {
                AppLog.error("Watch active job missing gatewaySessionKey jobId=\(watchJob.id)")
                continue
            }
            do {
                let messages = try await jobClient.fetchHistory(sessionKey: sessionKey)
                guard let reply = latestAssistantText(in: messages, after: watchJob.createdAt) else {
                    AppLog.info("No history reply yet for Watch jobId=\(watchJob.id) sessionKey=\(sessionKey)")
                    continue
                }
                var done = watchJob
                done.status = .done
                done.statusDetail = nil
                done.resultText = reply
                done.completedAt = Date()
                done.gatewaySessionKey = sessionKey
                if !jobs.contains(where: { $0.id == done.id }) {
                    jobs.insert(done, at: 0)
                }
                if activeJobId == done.id { activeJobId = nil }
                syncWatch(job: done)
                AppLog.info("Reconciled Watch job from history jobId=\(done.id) sessionKey=\(sessionKey) replyLength=\(reply.count)")
            } catch {
                AppLog.error("History reconcile failed jobId=\(watchJob.id) sessionKey=\(sessionKey): \(error.localizedDescription)")
            }
        }
    }

    private func latestAssistantText(in messages: [ChatHistoryMessage], after createdAt: Date) -> String? {
        let threshold = createdAt.addingTimeInterval(-10)
        return messages
            .filter { !$0.isUser && ($0.createdAt ?? .distantPast) >= threshold }
            .last?
            .text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // ─── Ariadne's Thread [AT-0042] ─────────────────────
    // What: Restore missing iPhone gateway URL from the Watch requestSync snapshot.
    // Why:  Locked/background iPhone WSS probe needs its Keychain URL; Watch can only provide the cached URL, not tokens.
    // Date: 2026-06-07
    // Related: WatchConnectivityWatchService.requestSync, publishGatewayProbeToWatch
    // ─────────────────────────────────────────────────────
    private func restoreGatewayURLFromWatchRequest(_ snapshot: PairingSnapshot?) {
        guard KeychainStore.loadGatewayURL() == nil,
              let rawURL = snapshot?.gatewayURL,
              let url = URL(string: rawURL) else {
            return
        }
        KeychainStore.saveGatewayURLForLockedAccess(url)
        AppLog.info("Restored missing iPhone gateway URL from Watch requestSync url=\(url.absoluteString) hasOperatorToken=\(KeychainStore.loadOperatorToken() != nil)")
    }

    // ─── Ariadne's Thread [AT-0038] ─────────────────────
    // What: Publish real gateway WSS hello-ok probe result to Watch.
    // Why:  Watch Speak must unlock only after iPhone proves the gateway socket path works.
    // Date: 2026-06-07
    // Related: [AT-0036] FlowLog, Gateway runbook liveness (connect -> hello-ok)
    // ─────────────────────────────────────────────────────
    func publishGatewayProbeToWatch(reason: String) async {
        if !KeychainStore.isPaired, let url = KeychainStore.loadGatewayURL() {
            do {
                AppLog.info("Gateway probe recovering pairing before probe reason=\(reason)")
                pairing = try await pairingClient.recheckApproval(gatewayURL: url, bootstrapToken: loadBootstrapFromKeychain())
                syncWatch()
            } catch {
                AppLog.error("Gateway probe pairing recovery failed reason=\(reason): \(error.localizedDescription)")
            }
        }
        let detail = await jobClient.probeGatewayHelloOk()
        let reachable = detail == "wss hello-ok"
        let envelope = WatchEnvelope(kind: .gatewayProbe, gatewayReachable: reachable, gatewayProbeDetail: "\(reason) \(detail)")
        watchBridge.sendCommandToWatch(envelope)
        AppLog.info("Published gateway probe to Watch reachable=\(reachable) detail=\(reason) \(detail)")
    }

    // ─── Ariadne's Thread [AT-0055] ─────────────────────
    // What: Expose the iPhone WSS hello-ok probe for Watch-requested relay tests.
    // Why:  WatchConnectivity sendMessage and transferUserInfo tests need a reply produced by the iPhone route itself.
    // Date: 2026-06-07
    // Related: [AT-0038] AppModel.publishGatewayProbeToWatch, [AT-0054] watch→WatchConnectivityWatchService.runIndependentWSSProbesIfNeeded
    // ─────────────────────────────────────────────────────
    func probeWSSForWatchRelay(requestId: String, route: String) async -> [String: Any] {
        let detail = await jobClient.probeGatewayHelloOk()
        let ok = detail == "wss hello-ok"
        let reply: [String: Any] = [
            "ok": ok,
            "route": route,
            "proof": ok ? "wss-hello-ok" : "failed",
            "detail": detail,
            "requestId": requestId,
        ]
        AppLog.info("IPHONE RELAY WSS result requestId=\(requestId) ok=\(ok) route=\(route) proof=\(ok ? "wss-hello-ok" : "failed") detail=\(detail)")
        return reply
    }

    // ─── Ariadne's Thread [AT-0025] ─────────────────────
    // What: Forward a Watch-recorded audio file to OpenClaw as a chat.send attachment.
    // Why:  OpenClaw tools.media.audio performs the boxed batch transcription; the iPhone does not run STT.
    // Date: 2026-06-06
    // Related: app→WatchConnectivityPhoneService didReceive file, app→GatewayJobClient runAudioAttachment
    // ─────────────────────────────────────────────────────
    func handleWatchAudioFile(fileURL: URL, jobId: UUID, sessionKey: String, fileName: String, mimeType: String) async {
        let jobLogId = String(jobId.uuidString.prefix(3))
        FlowLog.function(step: 5, side: .iphone, flow: "audio-send-server", name: "AppModel.handleWatchAudioFile")
        guard isPaired else {
            FlowLog.result(step: 5, side: .iphone, flow: "audio-send-server", success: false, detail: "not paired jobId=\(jobId)")
            FlowLog.finished(step: 5, side: .iphone, flow: "audio-send-server")
            AppLog.error("Watch audio file blocked: not paired jobId=\(jobId)")
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let job = VoiceJob(
            id: jobId,
            status: .sending,
            statusDetail: "Transcribing…",
            gatewaySessionKey: sessionKey,
            agentId: agentId(fromSessionKey: sessionKey) ?? "main"
        )
        if let existing = jobs.firstIndex(where: { $0.id == jobId }) {
            jobs[existing] = job
        } else {
            jobs.insert(job, at: 0)
        }
        activeJobId = jobId
        syncWatch(job: job)
        BackgroundAudioKeepAlive.begin(reason: "watchAudioFile")
        defer { BackgroundAudioKeepAlive.end(reason: "watchAudioFile") }

        do {
            let audioData = try Data(contentsOf: fileURL)
            FlowLog.progress(step: 5, side: .iphone, flow: "audio-send-server", detail: "uploading to gateway jobId=\(jobId) bytes=\(audioData.count) internetAvailable=\(PhoneNetworkPathMonitor.shared.internetAvailable)")
            AppLog.info("[IPHONE][JOB \(jobLogId)] backend send started jobId=\(jobId) sessionKey=\(sessionKey) bytes=\(audioData.count) fileName=\(fileName) mimeType=\(mimeType)")
            AppLog.info("Watch audio file forwarding to OpenClaw jobId=\(jobId) sessionKey=\(sessionKey) bytes=\(audioData.count) fileName=\(fileName) mimeType=\(mimeType)")
            // ─── Ariadne's Thread [AT-0065] ─────────────────────
            // What: Submit Watch audio only until Gateway accepts the job, then return Processing to Watch.
            // Why:  iPhone relay must not hold one long WSS open while the backend agent is working.
            // Date: 2026-06-08
            // Related: [AT-0044] app→GatewayJobClient.submitAudioAttachment, [AT-0046] AppModel.resumePendingAudioJobs
            // ─────────────────────────────────────────────────────
            let submitted = try await jobClient.submitAudioAttachment(
                audioData: audioData,
                fileName: fileName,
                mimeType: mimeType,
                sessionKey: sessionKey,
                idempotencyKey: jobId.uuidString
            )
            let pending = PendingAudioJob(
                watchJobId: jobId,
                sessionKey: sessionKey,
                chatSendId: submitted.chatSendId,
                idempotencyKey: jobId.uuidString,
                acceptedAt: submitted.acceptedAt,
                historyBaselineAssistantCount: submitted.historyBaselineAssistantCount,
                lastCheckedAt: nil
            )
            upsertPendingAudioJob(pending)
            guard let idx = jobs.firstIndex(where: { $0.id == jobId }) else { return }
            jobs[idx].status = .running
            jobs[idx].statusDetail = "Processing…"
            jobs[idx].completedAt = nil
            jobs[idx].gatewayRunId = submitted.chatSendId
            jobs[idx].gatewaySessionKey = sessionKey
            jobs[idx].failureSource = nil
            jobs[idx].elapsedSinceSend = nil
            jobs[idx].elapsedSinceLastWSFrame = nil
            jobs[idx].elapsedSinceWorking = nil
            jobs[idx].wsCloseCode = nil
            jobs[idx].backendErrorCode = nil
            syncWatch(job: jobs[idx])
            AppLog.info("[IPHONE][JOB \(jobLogId)] backend accepted async jobId=\(jobId) serverJobId=\(submitted.chatSendId) baselineAssistantCount=\(submitted.historyBaselineAssistantCount)")
            AppLog.info("[IPHONE][JOB \(jobLogId)] sent result to Watch jobId=\(jobId) status=processing serverJobId=\(submitted.chatSendId)")
            FlowLog.result(step: 5, side: .iphone, flow: "audio-send-server", success: true, detail: "accepted by server jobId=\(jobId) serverJobId=\(submitted.chatSendId)")
            FlowLog.finished(step: 5, side: .iphone, flow: "audio-send-server")
        } catch {
            guard let idx = jobs.firstIndex(where: { $0.id == jobId }) else { return }
            let failureDiagnostics = (error as? GatewayJobError)?.diagnostics
            AppLog.info("[IPHONE][JOB \(jobLogId)] backend send finished status=failed jobId=\(jobId) error=\(error.localizedDescription)")
            AppLog.error("[IPHONE][JOB \(jobLogId)] failure diagnostics jobId=\(jobId) source=\(failureDiagnostics?.failureSource ?? "unknown") elapsedSinceSend=\(failureDiagnostics?.elapsedSinceSend ?? -1) elapsedSinceLastWSFrame=\(failureDiagnostics?.elapsedSinceLastWSFrame ?? -1) elapsedSinceWorking=\(failureDiagnostics?.elapsedSinceWorking ?? -1) runId=\(failureDiagnostics?.runId ?? "nil") wsCloseCode=\(failureDiagnostics?.wsCloseCode ?? "nil") backendErrorCode=\(failureDiagnostics?.backendErrorCode ?? "nil")")
            jobs[idx].status = .failed
            jobs[idx].errorMessage = error.localizedDescription
            jobs[idx].statusDetail = nil
            jobs[idx].completedAt = Date()
            jobs[idx].failureSource = failureDiagnostics?.failureSource ?? "submitFailed"
            jobs[idx].elapsedSinceSend = failureDiagnostics?.elapsedSinceSend
            jobs[idx].elapsedSinceLastWSFrame = failureDiagnostics?.elapsedSinceLastWSFrame
            jobs[idx].elapsedSinceWorking = failureDiagnostics?.elapsedSinceWorking
            jobs[idx].gatewayRunId = failureDiagnostics?.runId
            jobs[idx].wsCloseCode = failureDiagnostics?.wsCloseCode
            jobs[idx].backendErrorCode = failureDiagnostics?.backendErrorCode
            if activeJobId == jobId { activeJobId = nil }
            errorBanner = error.localizedDescription
            syncWatch(job: jobs[idx])
            AppLog.info("[IPHONE][JOB \(jobLogId)] sent result to Watch jobId=\(jobId) status=failed error=\(error.localizedDescription)")
            FlowLog.result(step: 5, side: .iphone, flow: "audio-send-server", success: false, detail: "upload failed jobId=\(jobId) error=\(error.localizedDescription)")
            FlowLog.finished(step: 5, side: .iphone, flow: "audio-send-server")
            FlowLog.started(step: 6, side: .iphone, flow: "server-response", detail: "jobId=\(jobId)")
            FlowLog.function(step: 6, side: .iphone, flow: "server-response", name: "AppModel.handleWatchAudioFile")
            FlowLog.result(step: 6, side: .iphone, flow: "server-response", success: false, detail: "received=no error=\(error.localizedDescription)")
            FlowLog.finished(step: 6, side: .iphone, flow: "server-response")
            AppLog.error("Watch audio file OpenClaw reply failed jobId=\(jobId): \(error.localizedDescription)")
        }
    }

    // ─── Ariadne's Thread [AT-0061] ─────────────────────
    // What: Recover Watch audio replies from chat.history when live WSS reports an empty final response.
    // Why:  The gateway can persist a non-empty assistant message even when the live frame parser sees empty completion.
    // Date: 2026-06-08
    // Related: [AT-0027] GatewayJobClient.runAudioAttachment, [AT-0050] AppModel.reconcileActiveWatchJobsFromHistory
    // ─────────────────────────────────────────────────────
    private func recoverWatchAudioReplyFromHistory(jobId: UUID, sessionKey: String) async -> String? {
        do {
            let messages = try await jobClient.fetchHistory(sessionKey: sessionKey)
            let createdAt = jobs.first(where: { $0.id == jobId })?.createdAt ?? Date()
            let reply = latestAssistantText(in: messages, after: createdAt)
            AppLog.info("Watch audio empty-response recovery jobId=\(jobId) sessionKey=\(sessionKey) replyLength=\(reply?.count ?? 0)")
            return reply
        } catch {
            AppLog.error("Watch audio empty-response recovery failed jobId=\(jobId) sessionKey=\(sessionKey): \(error.localizedDescription)")
            return nil
        }
    }

    private func upsertPendingAudioJob(_ pending: PendingAudioJob) {
        if let index = pendingAudioJobs.firstIndex(where: { $0.watchJobId == pending.watchJobId }) {
            pendingAudioJobs[index] = pending
        } else {
            pendingAudioJobs.append(pending)
        }
        savePendingAudioJobs()
        AppLog.info("Pending audio job stored jobId=\(pending.watchJobId) sessionKey=\(pending.sessionKey) chatSendId=\(pending.chatSendId) baseline=\(pending.historyBaselineAssistantCount)")
    }

    func triggerPendingAudioResume(reason: String) {
        guard !pendingAudioJobs.isEmpty else {
            AppLog.info("Pending audio resume skipped reason=\(reason): no pending jobs")
            return
        }
        guard pendingResumeTask == nil else {
            AppLog.info("Pending audio resume already running reason=\(reason)")
            return
        }
        pendingResumeTask = Task { [weak self] in
            guard let self else { return }
            await self.resumePendingAudioJobs(reason: reason)
            await MainActor.run {
                self.pendingResumeTask = nil
            }
        }
    }

    // ─── Ariadne's Thread [AT-0046] ─────────────────────
    // What: Reconcile accepted Watch audio jobs by fetching Gateway history later.
    // Why:  Any Watch/iPhone wake should recover final replies without relying on the original WSS staying alive.
    // Date: 2026-06-07
    // Related: [AT-0045] AppModel.PendingAudioJob, [AT-0044] GatewayJobClient.submitAudioAttachment
    // ─────────────────────────────────────────────────────
    func resumePendingAudioJobs(reason: String) async {
        guard isPaired else {
            AppLog.info("Pending audio resume skipped reason=\(reason): not paired")
            return
        }
        guard !pendingAudioJobs.isEmpty else {
            AppLog.info("Pending audio resume skipped reason=\(reason): no pending jobs")
            return
        }
        AppLog.info("Pending audio resume started reason=\(reason) count=\(pendingAudioJobs.count)")

        for pending in pendingAudioJobs {
            if let index = pendingAudioJobs.firstIndex(where: { $0.watchJobId == pending.watchJobId }) {
                pendingAudioJobs[index].lastCheckedAt = Date()
                savePendingAudioJobs()
            }

            do {
                let reply = try await jobClient.latestAssistantReplyAfterBaseline(
                    sessionKey: pending.sessionKey,
                    baselineAssistantCount: pending.historyBaselineAssistantCount
                )
                guard let reply, !reply.isEmpty else {
                    ensureProcessingJobExists(for: pending)
                    continue
                }
                finishPendingAudioJob(pending, reply: reply)
            } catch {
                AppLog.error("Pending audio resume failed jobId=\(pending.watchJobId) sessionKey=\(pending.sessionKey): \(error.localizedDescription)")
                ensureProcessingJobExists(for: pending)
            }
        }

        AppLog.info("Pending audio resume finished reason=\(reason) remaining=\(pendingAudioJobs.count)")
    }

    private func ensureProcessingJobExists(for pending: PendingAudioJob) {
        if let index = jobs.firstIndex(where: { $0.id == pending.watchJobId }) {
            guard jobs[index].status == .sending || jobs[index].status == .running else { return }
            jobs[index].status = .running
            jobs[index].statusDetail = "Processing…"
            syncWatch(job: jobs[index])
            return
        }
        let job = VoiceJob(
            id: pending.watchJobId,
            status: .running,
            statusDetail: "Processing…",
            gatewayRunId: pending.chatSendId,
            gatewaySessionKey: pending.sessionKey,
            agentId: agentId(fromSessionKey: pending.sessionKey) ?? "main",
            createdAt: pending.acceptedAt
        )
        jobs.insert(job, at: 0)
        activeJobId = pending.watchJobId
        syncWatch(job: job)
    }

    private func finishPendingAudioJob(_ pending: PendingAudioJob, reply: String) {
        let completed = Date()
        let updated: VoiceJob
        if let index = jobs.firstIndex(where: { $0.id == pending.watchJobId }) {
            jobs[index].status = .done
            jobs[index].statusDetail = nil
            jobs[index].resultText = reply
            jobs[index].completedAt = completed
            jobs[index].gatewayRunId = pending.chatSendId
            jobs[index].gatewaySessionKey = pending.sessionKey
            updated = jobs[index]
        } else {
            updated = VoiceJob(
                id: pending.watchJobId,
                status: .done,
                resultText: reply,
                gatewayRunId: pending.chatSendId,
                gatewaySessionKey: pending.sessionKey,
                agentId: agentId(fromSessionKey: pending.sessionKey) ?? "main",
                createdAt: pending.acceptedAt,
                completedAt: completed
            )
            jobs.insert(updated, at: 0)
        }
        if activeJobId == pending.watchJobId { activeJobId = nil }
        pendingAudioJobs.removeAll { $0.watchJobId == pending.watchJobId }
        savePendingAudioJobs()
        syncWatch(job: updated)
        FlowLog.started(step: 6, side: .iphone, flow: "server-response", detail: "jobId=\(pending.watchJobId) source=history")
        FlowLog.function(step: 6, side: .iphone, flow: "server-response", name: "AppModel.resumePendingAudioJobs")
        FlowLog.result(step: 6, side: .iphone, flow: "server-response", success: true, detail: "received=yes replyLength=\(reply.count)")
        FlowLog.finished(step: 6, side: .iphone, flow: "server-response")
        FlowLog.progress(step: 7, side: .iphone, flow: "display-reply", detail: "pushing reply to Watch jobId=\(pending.watchJobId) replyLength=\(reply.count)")
        AppLog.info("Pending audio job finished jobId=\(pending.watchJobId) replyLength=\(reply.count)")
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
        republishCachedUsageToWatch()
        if watchGatewaySessions.isEmpty {
            AppLog.info("Republish: no cached gateway sessions; refreshing from gateway")
            Task { await refreshSessions() }
        } else {
            AppLog.info("Republish skipped full agents/sessions; Watch will request missing data known to its cache")
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
            let transcript = try await speech.stopAndTranscribe(localeIdentifier: voiceLanguage)
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

    // ─── Ariadne's Thread [AT-0060] ─────────────────────
    // What: Stop sending historical jobsSnapshot during per-job status updates.
    // Why:  Watch active turns must receive only their current jobUpdated, not old done/failed jobs mixed into every push.
    // Date: 2026-06-08
    // Related: [AT-0025] AppModel.handleWatchAudioFile, [AT-0049] watch→WatchAppModel.upsert
    // ─────────────────────────────────────────────────────
    private func syncWatch(job: VoiceJob? = nil, revokeGatewayPairing: Bool = false) {
        if let job {
            watchBridge.publish(job: job)
            return
        }
        let activeJobs = jobs.filter { !$0.status.isTerminal && $0.status != .idle }
        watchBridge.publish(
            pairing: pairing,
            jobs: activeJobs,
            ttsEnabled: ttsEnabled,
            ttsLanguage: voiceLanguage,
            hapticType: hapticType.rawValue,
            ttsRate: ttsRate,
            revokeGatewayPairing: revokeGatewayPairing
        )
    }

    /// Builds a progress sink for a run: every streamed step from the gateway becomes the job's live `statusDetail`
    /// and is pushed to the Watch so both screens show what OpenClaw is currently doing.
    private func makeProgressHandler(jobId: UUID) -> @Sendable (String) -> Void {
        { [weak self] step in
            Task { @MainActor [weak self] in
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
