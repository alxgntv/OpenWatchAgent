import Combine
import Foundation
import SwiftUI
import WatchKit

/// One conversation on the Watch. Each session has its own gateway sessionKey and its own message history.
/// Swiping to the trailing empty session starts a brand-new conversation.
struct WatchSession: Identifiable, Equatable {
    let id: UUID
    let sessionKey: String
    var jobs: [VoiceJob]
    /// When true, replies in this session are not spoken aloud.
    var muted: Bool

    init(sessionKey: String) {
        self.id = UUID()
        self.sessionKey = sessionKey
        self.jobs = []
        self.muted = false
    }

    var isEmpty: Bool { jobs.isEmpty }
    var latestJob: VoiceJob? { jobs.first }
    var activeJob: VoiceJob? { jobs.first { !$0.status.isTerminal && $0.status != .idle } }
    var retryJob: VoiceJob? { jobs.first { $0.status == .failed && $0.statusDetail == "Retry" } }
}

// ─── Ariadne's Thread [AT-0098] ─────────────────────
// What: Add cache-first Watch store, UI snapshots, and serial events for Watch sync/UI data.
// Why:  SwiftUI lists must read stable value snapshots while WCSession callbacks and taps enter one MainActor reducer.
// Date: 2026-06-08
// Related: [AT-0097] shared→WatchSessionIndexDelta, [AT-0092] WatchConnectivityWatchService.didReceiveUserInfo
// ─────────────────────────────────────────────────────
struct WatchShellState: Equatable {
    var selectedHorizontalPage: Int = 2
    var isPaired: Bool = false
}

struct AgentListRowState: Identifiable, Equatable {
    let id: String
    let name: String
    let emoji: String?
    let subtitle: String?
    let modelLabel: String?
    let isDefault: Bool
}

struct AgentsListState: Equatable {
    var rows: [AgentListRowState] = []
}

struct SessionListRowState: Identifiable, Hashable {
    let id: String
    let title: String
    let preview: String?
    let updatedAt: Date?
    let hasActiveJob: Bool
}

struct SessionListState: Equatable {
    var rows: [SessionListRowState] = []
    var selectedAgentId: String = "main"
    var isLoading: Bool = false
}

struct SessionDetailState: Equatable {
    var sessionKey: String
    var title: String
    var updatedAt: Date?
    var messages: [WatchMessageRow]
    var liveJobs: [VoiceJob]
    var isLoading: Bool
}

private struct WatchStore {
    var agentsById: [String: WatchAgentRow] = [:]
    var agentOrder: [String] = []
    var selectedAgentId: String = "main"
    var sessionsById: [String: WatchSessionRow] = [:]
    var sessionOrderByAgentId: [String: [String]] = [:]
    var messagesBySessionKey: [String: [WatchMessageRow]] = [:]
}

enum WatchEvent {
    case transportEnvelope(WatchEnvelope, source: String)
    case sessionsPageAppeared(agentId: String)
    case sessionDetailAppeared(sessionKey: String)
    case horizontalPageChanged(Int)
}

@MainActor
final class WatchAppModel: ObservableObject {
    static let shared = WatchAppModel()

    @Published var pairing = PairingSnapshot()
    @Published var sessions: [WatchSession]
    /// Switching the visible session stops whatever the previous session was speaking.
    @Published var currentIndex: Int = 0 {
        didSet {
            guard oldValue != currentIndex else { return }
            lastSessionSwitchAt = Date()
            AppLog.info("Watch session switched \(oldValue) -> \(currentIndex); stopping any active speech")
            SpeechPlaybackService.shared.stop()
        }
    }
    /// Timestamp of the last vertical session switch. Used to swallow a Speak tap that is really the tail end of a
    /// page-swipe gesture, so changing sessions never auto-starts a recording.
    private var lastSessionSwitchAt: Date?
    /// How long after a session switch a Speak tap is treated as an accidental swipe tail and ignored.
    private let sessionSwitchTapGuardInterval: TimeInterval = 0.4
    /// Selected HORIZONTAL page: 0 = Usage, 1 = Agents, 2 = live stack (main), 3...N = gateway sessions.
    /// Defaults to 2 so the app always opens on the main screen.
    @Published var horizontalIndex: Int = 2 {
        didSet {
            guard oldValue != horizontalIndex else { return }
            AppLog.info("Watch horizontal page switched \(oldValue) -> \(horizontalIndex)")
        }
    }
    @Published var statusHint: String?
    /// Global "speak replies" switch, mirrored from the iPhone app. Defaults to on until the phone tells us otherwise.
    @Published var globalTtsEnabled: Bool = true
    /// BCP-47 language used to speak replies, mirrored from the iPhone app.
    @Published var globalTtsLanguage: String = "en-US"
    /// Speech rate multiplier used to speak replies, mirrored from the iPhone app.
    @Published var globalTtsRate: Double = 1.0
    /// Haptic feedback played when Watch recording starts/stops, mirrored from the iPhone app.
    @Published var hapticType: WatchHapticType = .start
    /// Real gateway session index mirrored from the iPhone — shown in the Sessions list/navigation.
    @Published var gatewaySessions: [WatchGatewaySession] = []
    @Published var gatewaySessionsLoading = false
    /// Aggregate usage mirrored from the iPhone — shown on the Usage page.
    @Published var usage: WatchUsage?
    /// Configured agents mirrored from the iPhone — shown on the Agents page.
    @Published var gatewayAgents: [WatchGatewayAgent] = []
    /// Active agent id mirrored from the iPhone (filters gateway session pages).
    @Published var selectedAgentId: String = "main"
    @Published private(set) var shellState = WatchShellState()
    @Published private(set) var agentsListState = AgentsListState()
    @Published private(set) var sessionListState = SessionListState()
    @Published private var sessionDetailStates: [String: SessionDetailState] = [:]

    private let bridge = WatchConnectivityWatchService.shared
    private let recorder = WatchAudioRecorder()
    private var watchStore = WatchStore()
    private var pendingWatchEvents: [WatchEvent] = []
    private var isReducingWatchEvents = false
    /// Local jobs the iPhone has not acknowledged yet.
    private var pendingJobIds: Set<UUID> = []
    /// Maps a jobId to the session it belongs to, so iPhone-driven updates land on the right screen.
    private var jobSession: [UUID: UUID] = [:]
    /// Jobs whose reply has already been spoken aloud, so TTS never restarts/loops on repeated updates.
    private var spokenJobIds: Set<UUID> = []
    /// The session that the in-progress recording will be attached to (captured at record start).
    private var recordingSessionId: UUID?
    /// Live turns the Watch started inside a gateway-session page, keyed by gateway sessionKey (newest-first).
    /// Kept separate from `gatewaySessions` (which the iPhone overwrites on every push) so local turns survive refreshes.
    @Published private var gatewayJobs: [String: [VoiceJob]] = [:]
    /// Maps a jobId to a gateway sessionKey when the recording was started on a gateway page.
    private var jobGatewayKey: [UUID: String] = [:]
    /// The gateway sessionKey the in-progress recording belongs to (set when recording starts on a gateway page).
    private var gatewayRecordingKey: String?
    /// Gateway sessionKeys whose replies are muted on the Watch (local, per-session). Not persisted/synced.
    @Published private var gatewayMutedKeys: Set<String> = []
    private var recordingJobId: UUID?
    private var jobLastUpdateAt: [UUID: Date] = [:]
    private var jobLastWatchdogSyncAt: [UUID: Date] = [:]
    private var jobPollingStartedAt: [UUID: Date] = [:]
    private var lastGatewaySessionsFingerprint: String?
    private var pendingAgentTapId: String?
    private var agentNavigationStateFrozen = false
    // ─── Ariadne's Thread [AT-0109] ─────────────────────
    // What: Keep Main-screen agent selection separate from WatchStore.selectedAgentId.
    // Why:  Checkpoint logs showed signal 6 immediately after mutating WatchStore.selectedAgentId during Agents -> Main navigation.
    // Date: 2026-06-08
    // Related: [AT-0099] WatchAppModel.reduceAgentTapped, [AT-0108] WatchAppModel.beginRecording
    // ─────────────────────────────────────────────────────
    private var mainAgentId: String = "main"
    private var pendingSessionIndexRequestAgentId: String?

    // ─── Ariadne's Thread [AT-0094] ─────────────────────
    // What: Split gateway messages out of the published gateway session index.
    // Why:  Message deltas must update the open session page without rewriting the List/NavigationLink source array on watchOS.
    // Date: 2026-06-08
    // Related: [AT-0079] WatchAppModel.requestMissingGatewayMessagesForSession, [AT-0076] WatchHomeView.GatewaySessionPage
    // ─────────────────────────────────────────────────────
    @Published private var gatewayMessagesBySessionKey: [String: [WatchHistoryMessage]] = [:]

    // ─── Ariadne's Thread [AT-0002] ─────────────────────
    // What: UserDefaults cache of last connected gateway pairing on the Watch.
    // Why:  After battery drain the app cold-starts before iPhone sync; cached .connected
    //       keeps the main UI while requestSync restores full state.
    // Date: 2026-06-04
    // Related: [AT-0001] WatchConnectivityPhoneService enrichWatchEnvelope
    // ─────────────────────────────────────────────────────
    private enum PairingLocalCache {
        static let wasConnectedKey = "watch.pairing.wasConnected"
        static let gatewayURLKey = "watch.pairing.gatewayURL"
        static let deviceIdKey = "watch.pairing.deviceId"
        static let gatewaySessionsKey = "watch.gatewaySessions.v2"
        static let gatewayAgentsKey = "watch.gatewayAgents.v1"
        static let selectedAgentIdKey = "watch.selectedAgentId.v1"
    }
    private static let cachedMessageTextLimit = 500

    // ─── Ariadne's Thread [AT-0125] ─────────────────────
    // What: Compact the Watch gateway session cache to session index rows only.
    // Why:  watchOS rejects UserDefaults writes once cached transcript messages push the preferences domain over 1 MB.
    // Date: 2026-06-09
    // Related: [AT-0094] WatchAppModel.gatewayMessagesBySessionKey, [AT-0093] WatchAppModel.saveSelectedGatewayAgentId
    // ─────────────────────────────────────────────────────
    private init() {
        sessions = [WatchSession(sessionKey: "agent:main:main")]
        let cachedGatewaySessions = Self.loadCachedGatewaySessions()
        gatewaySessions = Self.gatewaySessionIndex(from: cachedGatewaySessions)
        gatewayMessagesBySessionKey = Self.gatewayMessagesBySessionKey(from: cachedGatewaySessions)
        let cachedAgents = Self.loadCachedGatewayAgents()
        gatewayAgents = cachedAgents.agents
        selectedAgentId = cachedAgents.selectedAgentId
        mainAgentId = cachedAgents.selectedAgentId
        hydrateWatchStore(agents: cachedAgents.agents, sessions: gatewaySessions, messages: gatewayMessagesBySessionKey, selectedAgentId: cachedAgents.selectedAgentId)
        restorePairingFromLocalCache()
        rebuildWatchSnapshots()
    }

    // ─── Ariadne's Thread [AT-0099] ─────────────────────
    // What: Route Watch UI and WCSession changes through one MainActor event reducer.
    // Why:  Row taps and transport callbacks must not mutate SwiftUI-backed arrays during List/Navigation transactions.
    // Date: 2026-06-08
    // Related: [AT-0098] WatchStore, [AT-0097] shared→WatchSessionMessagesDelta
    // ─────────────────────────────────────────────────────
    func send(_ event: WatchEvent) {
        pendingWatchEvents.append(event)
        AppLog.info("Watch event enqueued \(Self.describe(event)) pending=\(pendingWatchEvents.count)")
        guard !isReducingWatchEvents else { return }
        isReducingWatchEvents = true
        Task { @MainActor in
            await Task.yield()
            while !pendingWatchEvents.isEmpty {
                let next = pendingWatchEvents.removeFirst()
                reduce(next)
            }
            isReducingWatchEvents = false
        }
    }

    private static func describe(_ event: WatchEvent) -> String {
        switch event {
        case .transportEnvelope(let envelope, let source):
            return "transportEnvelope kind=\(envelope.kind.rawValue) source=\(source)"
        case .sessionsPageAppeared(let agentId):
            return "sessionsPageAppeared agentId=\(agentId)"
        case .sessionDetailAppeared(let sessionKey):
            return "sessionDetailAppeared sessionKey=\(sessionKey)"
        case .horizontalPageChanged(let page):
            return "horizontalPageChanged page=\(page)"
        }
    }

    private func reduce(_ event: WatchEvent) {
        AppLog.info("Watch reducer start \(Self.describe(event))")
        switch event {
        case .transportEnvelope(let envelope, let source):
            reduceTransportEnvelope(envelope, source: source)
        case .sessionsPageAppeared(let agentId):
            reduceSessionsPageAppeared(agentId: agentId)
        case .sessionDetailAppeared(let sessionKey):
            reduceSessionDetailAppeared(sessionKey: sessionKey)
        case .horizontalPageChanged(let page):
            horizontalIndex = page
            if page == 2 {
                commitPendingAgentTapIfNeeded(source: "horizontalPageChanged-main")
            }
        }
        AppLog.info("Watch reducer finished \(Self.describe(event))")
    }

    private func reduceTransportEnvelope(_ envelope: WatchEnvelope, source: String) {
        AppLog.info("Watch reducer envelope kind=\(envelope.kind.rawValue) source=\(source) pairingPhase=\(envelope.pairing?.phase.rawValue ?? "unchanged") revoke=\(envelope.revokeGatewayPairing == true)")
        applyRemotePairingAndTts(from: envelope)
        switch envelope.kind {
        case .pairingSnapshot:
            rebuildWatchSnapshots()
        case .jobsSnapshot:
            if let snapshot = envelope.jobs {
                AppLog.info("Watch reducer applying jobsSnapshot count=\(snapshot.count)")
                for job in snapshot { upsert(job) }
            }
        case .jobUpdated:
            if let job = envelope.job {
                logStep6ServerResponse(job: job)
                upsert(job)
            }
        case .startListening:
            if let agentId = envelope.text?.trimmingCharacters(in: .whitespacesAndNewlines), !agentId.isEmpty {
                applySelectedAgent(agentId, resetLiveSession: false, notifyPhone: false, source: "remote-startListening")
                AppLog.info("Watch reducer received remote startListening for agentId=\(agentId)")
            } else {
                AppLog.info("Watch reducer received remote startListening without agent id")
            }
            handleRemoteStartListening()
        case .agentIndexDelta:
            if let delta = envelope.agentIndexDelta {
                applyAgentIndexDelta(delta, source: source)
            }
        case .agents:
            let delta = WatchAgentIndexDelta(agents: envelope.gatewayAgents ?? [], selectedAgentId: envelope.selectedAgentId)
            applyAgentIndexDelta(delta, source: "legacy-agents-\(source)")
        case .sessionIndexDelta:
            if let delta = envelope.sessionIndexDelta {
                applySessionIndexDelta(delta, source: source)
            }
        case .sessionMessagesDelta:
            if let delta = envelope.sessionMessagesDelta {
                applySessionMessagesDelta(delta, source: source)
            }
        case .gatewaySessions:
            reduceLegacyGatewaySessions(envelope, source: source)
        case .usage:
            if let usage = envelope.usage {
                self.usage = usage
                AppLog.info("Watch reducer received usage agents=\(usage.agentCount) sessions=\(usage.sessionCount) totalTokens=\(usage.totalTokens)")
            }
        case .gatewayProbe:
            WatchConnectivityWatchService.shared.applyGatewayProbe(
                reachable: envelope.gatewayReachable == true,
                detail: envelope.gatewayProbeDetail
            )
        default:
            break
        }
    }

    private func reduceLegacyGatewaySessions(_ envelope: WatchEnvelope, source: String) {
        guard let sessions = envelope.gatewaySessions else { return }
        let rows = sessions.map { WatchSessionRow(session: $0) }
        applySessionIndexDelta(
            WatchSessionIndexDelta(selectedAgentId: envelope.selectedAgentId ?? selectedAgentId, sessions: rows),
            source: "legacy-gatewaySessions-\(source)"
        )
        for session in sessions where !session.messages.isEmpty {
            applySessionMessagesDelta(
                WatchSessionMessagesDelta(sessionKey: session.id, messages: session.messages),
                source: "legacy-gatewaySessions-\(source)"
            )
        }
        AppLog.info("Watch converted legacy gatewaySessions payload rows=\(rows.count) messageSessions=\(sessions.filter { !$0.messages.isEmpty }.count)")
    }

    var mainAgentIdForUI: String {
        mainAgentId
    }

    func setMainAgentIdForNextRecording(_ agentId: String) {
        pendingAgentTapId = nil
        mainAgentId = agentId
        selectedAgentId = agentId
        horizontalIndex = 2
        UserDefaults.standard.set(mainAgentId, forKey: PairingLocalCache.selectedAgentIdKey)
        AppLog.info("Watch set main agent id for next recording agentId=\(agentId) and returned to live page without requesting iPhone session data")
    }

    private func commitPendingAgentTapIfNeeded(source: String) {
        guard let agentId = pendingAgentTapId else { return }
        pendingAgentTapId = nil
        AppLog.info("Watch committed pending main agent id=\(agentId) without touching WatchStore.selectedAgentId source=\(source)")
    }

    private func reduceSessionsPageAppeared(agentId: String) {
        requestSessionIndexForCurrentAgent(source: "sessionsPageAppeared requestedAgentId=\(agentId)")
    }

    // ─── Ariadne's Thread [AT-0110] ─────────────────────
    // What: Add native pull-to-refresh request flow for the Watch Sessions page.
    // Why:  Pulling the Sessions screen down must ask the iPhone for missing rows for the currently selected agent.
    // Date: 2026-06-09
    // Related: [AT-0101] WatchHomeView.GatewaySessionsListPage, [AT-0100] WatchConnectivityWatchService.requestSessionIndexDelta
    // ─────────────────────────────────────────────────────
    func refreshSessionsForCurrentAgent() async {
        requestSessionIndexForCurrentAgent(source: "pullToRefresh")
        let startedAt = Date()
        while sessionListState.isLoading && Date().timeIntervalSince(startedAt) < 10 {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                AppLog.error("Watch sessions pull-to-refresh cancelled agentId=\(mainAgentId): \(error.localizedDescription)")
                break
            }
        }
        if sessionListState.isLoading {
            sessionListState.isLoading = false
            AppLog.error("Watch sessions pull-to-refresh timed out agentId=\(mainAgentId) rows=\(sessionListState.rows.count)")
        } else {
            AppLog.info("Watch sessions pull-to-refresh finished agentId=\(mainAgentId) rows=\(sessionListState.rows.count)")
        }
    }

    private func requestSessionIndexForCurrentAgent(source: String) {
        let currentAgentId = mainAgentId
        horizontalIndex = 3
        if !sessionDetailStates.isEmpty {
            AppLog.info("Watch cleared session detail states before sessions index request count=\(sessionDetailStates.count) source=\(source)")
            sessionDetailStates.removeAll()
        }
        sessionListState = buildSessionListState(isLoading: true)
        pendingSessionIndexRequestAgentId = currentAgentId
        let knownSessionIds = watchStore.sessionOrderByAgentId[currentAgentId] ?? []
        AppLog.info("Watch requested sessions index agentId=\(currentAgentId) knownSessions=\(knownSessionIds.count) source=\(source)")
        bridge.requestSessionIndexDelta(
            knownAgentIds: watchStore.agentOrder,
            knownSessionIds: knownSessionIds,
            selectedAgentId: currentAgentId
        )
    }

    private func reduceSessionDetailAppeared(sessionKey: String) {
        requestSessionMessages(sessionKey: sessionKey, source: "sessionDetailAppeared")
    }

    // ─── Ariadne's Thread [AT-0115] ─────────────────────
    // What: Add native pull-to-refresh request flow for one Watch session detail.
    // Why:  Pulling inside an opened session must reload missing text messages from the iPhone.
    // Date: 2026-06-09
    // Related: [AT-0095] WatchHomeView.GatewaySessionPage, [AT-0100] WatchConnectivityWatchService.requestSessionMessagesDelta
    // ─────────────────────────────────────────────────────
    func refreshSessionMessages(sessionKey: String) async {
        requestSessionMessages(sessionKey: sessionKey, source: "pullToRefresh")
        let startedAt = Date()
        while sessionDetailState(for: sessionKey).isLoading && Date().timeIntervalSince(startedAt) < 10 {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                AppLog.error("Watch session detail pull-to-refresh cancelled sessionKey=\(sessionKey): \(error.localizedDescription)")
                break
            }
        }
        if sessionDetailState(for: sessionKey).isLoading {
            updateSessionDetailState(sessionKey: sessionKey, isLoading: false)
            AppLog.error("Watch session detail pull-to-refresh timed out sessionKey=\(sessionKey) messages=\(sessionDetailState(for: sessionKey).messages.count)")
        } else {
            AppLog.info("Watch session detail pull-to-refresh finished sessionKey=\(sessionKey) messages=\(sessionDetailState(for: sessionKey).messages.count)")
        }
    }

    private func requestSessionMessages(sessionKey: String, source: String) {
        let knownMessageIds = watchStore.messagesBySessionKey[sessionKey]?.map(\.id) ?? []
        updateSessionDetailState(sessionKey: sessionKey, isLoading: true)
        AppLog.info("Watch requested session messages sessionKey=\(sessionKey) knownMessages=\(knownMessageIds.count) source=\(source)")
        bridge.requestSessionMessagesDelta(
            sessionKey: sessionKey,
            knownAgentIds: watchStore.agentOrder,
            knownSessionIds: watchStore.sessionOrderByAgentId[mainAgentId] ?? [],
            knownMessageIds: knownMessageIds,
            selectedAgentId: mainAgentId
        )
    }

    private func hydrateWatchStore(
        agents: [WatchAgentRow],
        sessions: [WatchGatewaySession],
        messages: [String: [WatchMessageRow]],
        selectedAgentId: String
    ) {
        watchStore = WatchStore()
        watchStore.selectedAgentId = selectedAgentId
        applyAgentsToStore(Self.normalizeGatewayAgents(agents))
        let rows = Self.gatewaySessionIndex(from: sessions).map { WatchSessionRow(session: $0) }
        applySessionRowsToStore(rows, selectedAgentId: nil)
        for (key, value) in messages {
            watchStore.messagesBySessionKey[key] = Self.normalizeMessages(value)
        }
        AppLog.info("Watch store hydrated agents=\(watchStore.agentOrder.count) sessions=\(watchStore.sessionsById.count) messageSessions=\(watchStore.messagesBySessionKey.count) selectedAgentId=\(selectedAgentId)")
    }

    private func applyAgentsToStore(_ agents: [WatchAgentRow]) {
        for agent in agents {
            watchStore.agentsById[agent.id] = agent
            if !watchStore.agentOrder.contains(agent.id) {
                watchStore.agentOrder.append(agent.id)
            }
        }
        watchStore.agentOrder = Self.normalizeGatewayAgents(watchStore.agentOrder.compactMap { watchStore.agentsById[$0] }).map(\.id)
    }

    private func applySessionRowsToStore(_ rows: [WatchSessionRow], selectedAgentId: String?) {
        for row in rows {
            watchStore.sessionsById[row.id] = row
            let agentId = sessionAgentId(from: row.id)
            var order = watchStore.sessionOrderByAgentId[agentId] ?? []
            if !order.contains(row.id) {
                order.append(row.id)
            }
            watchStore.sessionOrderByAgentId[agentId] = order.sorted { lhs, rhs in
                let left = watchStore.sessionsById[lhs]?.updatedAt ?? .distantPast
                let right = watchStore.sessionsById[rhs]?.updatedAt ?? .distantPast
                return left > right
            }
        }
        if let selectedAgentId, !selectedAgentId.isEmpty {
            watchStore.selectedAgentId = selectedAgentId
            selectedAgentIdDidChange(selectedAgentId)
        }
    }

    private func applyAgentIndexDelta(_ delta: WatchAgentIndexDelta, source: String) {
        let normalized = Self.normalizeGatewayAgents(delta.agents)
        let previousAgents = watchStore.agentOrder.compactMap { watchStore.agentsById[$0] }
        if delta.isFullSnapshot == true {
            watchStore.agentsById = Dictionary(uniqueKeysWithValues: normalized.map { ($0.id, $0) })
            watchStore.agentOrder = normalized.map(\.id)
            AppLog.info("Watch replaced local agent navigation model agents=\(normalized.count) source=\(source)")
        } else {
            applyAgentsToStore(normalized)
        }
        let currentAgents = watchStore.agentOrder.compactMap { watchStore.agentsById[$0] }
        let agentsChanged = previousAgents != currentAgents
        if let selected = delta.selectedAgentId, !selected.isEmpty {
            AppLog.info("Watch ignored remote selectedAgentId=\(selected) localSelectedAgentId=\(watchStore.selectedAgentId) source=agentIndexDelta-\(source)")
        } else {
            AppLog.info("Watch agentIndexDelta had no selectedAgentId source=\(source)")
        }
        if agentsChanged {
            saveCachedGatewayAgents()
        } else {
            AppLog.info("Watch skipped identical gateway agent cache save count=\(currentAgents.count) source=\(source)")
        }
        if agentNavigationStateFrozen {
            AppLog.info("Watch cached agentIndexDelta without republishing frozen navigation state agents=\(currentAgents.count) source=\(source)")
        } else {
            publishAgentNavigationState(source: "agentIndexDelta-\(source)")
        }
        AppLog.info("Watch reducer applied agentIndexDelta agents=\(normalized.count) selectedAgentId=\(delta.selectedAgentId ?? "nil") source=\(source)")
    }

    // ─── Ariadne's Thread [AT-0114] ─────────────────────
    // What: Apply Watch session index deltas without rewriting legacy published session arrays.
    // Why:  The refreshable Sessions scroll view crashed when sessionIndexDelta republished gatewaySessions during navigation.
    // Date: 2026-06-09
    // Related: [AT-0112] WatchHomeView.GatewaySessionsListPage, [AT-0110] WatchAppModel.refreshSessionsForCurrentAgent
    // ─────────────────────────────────────────────────────
    private func applySessionIndexDelta(_ delta: WatchSessionIndexDelta, source: String) {
        guard sessionDetailStates.isEmpty else {
            AppLog.info("Watch skipped sessionIndexDelta while session detail is active rows=\(delta.sessions.count) source=\(source)")
            return
        }
        guard horizontalIndex == 3, pendingSessionIndexRequestAgentId != nil else {
            AppLog.info("Watch skipped sessionIndexDelta outside Sessions page rows=\(delta.sessions.count) page=\(horizontalIndex) pendingRequest=\(pendingSessionIndexRequestAgentId ?? "nil") source=\(source)")
            return
        }
        guard !delta.sessions.isEmpty else {
            pendingSessionIndexRequestAgentId = nil
            sessionListState.isLoading = false
            AppLog.info("Watch skipped empty sessionIndexDelta without cache save rows=0 existingRows=\(sessionListState.rows.count) source=\(source)")
            return
        }
        let beforeRows = sessionListState.rows.map(\.id)
        applySessionRowsToStore(delta.sessions, selectedAgentId: nil)
        pendingSessionIndexRequestAgentId = nil
        saveCachedGatewaySessions()
        sessionListState = buildSessionListState(isLoading: false)
        sessionListState.isLoading = false
        AppLog.info("Watch reducer applied sessionIndexDelta rows=\(delta.sessions.count) beforeRows=\(beforeRows.count) afterRows=\(sessionListState.rows.count) source=\(source)")
    }

    private func applySessionMessagesDelta(_ delta: WatchSessionMessagesDelta, source: String) {
        let beforeRows = sessionListState.rows.map(\.id)
        let incoming = Self.normalizeMessages(delta.messages)
        let existing = watchStore.messagesBySessionKey[delta.sessionKey] ?? []
        var seen = Set(existing.map(\.id))
        var merged = existing
        var added = 0
        for message in incoming where !seen.contains(message.id) {
            seen.insert(message.id)
            merged.append(message)
            added += 1
        }
        watchStore.messagesBySessionKey[delta.sessionKey] = merged
        gatewayMessagesBySessionKey[delta.sessionKey] = merged
        updateSessionDetailState(sessionKey: delta.sessionKey, isLoading: false)
        let afterRows = sessionListState.rows.map(\.id)
        if beforeRows != afterRows {
            AppLog.error("Watch invariant failed: SessionListState.rows changed during sessionMessagesDelta sessionKey=\(delta.sessionKey)")
        } else {
            AppLog.info("Watch invariant ok: sessionMessagesDelta did not change SessionListState.rows sessionKey=\(delta.sessionKey) added=\(added) source=\(source)")
        }
    }

    private func applySelectedAgent(
        _ agentId: String,
        resetLiveSession: Bool,
        notifyPhone: Bool,
        source: String
    ) {
        mainAgentId = agentId
        watchStore.selectedAgentId = agentId
        selectedAgentIdDidChange(agentId)
        if resetLiveSession {
            sessions = [WatchSession(sessionKey: newSessionKey(for: agentId))]
            currentIndex = 0
            horizontalIndex = 2
            shellState.selectedHorizontalPage = 2
            statusHint = nil
        }
        rebuildWatchSnapshots(updateSessionList: false, updateDetails: false)
        saveSelectedGatewayAgentId()
        if notifyPhone {
            bridge.sendCommand(WatchEnvelope(kind: .selectAgent, text: agentId))
        }
        AppLog.info("Watch selectedAgentChanged id=\(agentId) resetLiveSession=\(resetLiveSession) notifyPhone=\(notifyPhone) source=\(source)")
    }

    private func selectedAgentIdDidChange(_ agentId: String) {
        selectedAgentId = agentId
        watchStore.selectedAgentId = agentId
    }

    // ─── Ariadne's Thread [AT-0106] ─────────────────────
    // What: Keep session list rows out of agent selection and agent-index updates.
    // Why:  The latest Watch crash happened when agentIndexDelta rebuilt SessionListState during startup.
    // Date: 2026-06-08
    // Related: [AT-0099] WatchAppModel.reduceAgentTapped, [AT-0101] WatchHomeView.GatewaySessionsListPage
    // ─────────────────────────────────────────────────────
    private func rebuildWatchSnapshots(updateSessionList: Bool = true, updateDetails: Bool = true) {
        publishAgentNavigationState(source: "rebuildWatchSnapshots")
        if updateSessionList {
            syncLegacySessionIndexFromStore()
        }
        shellState = WatchShellState(selectedHorizontalPage: horizontalIndex, isPaired: isPaired)
        if updateSessionList {
            sessionListState = buildSessionListState(isLoading: sessionListState.isLoading)
        }
        if updateDetails {
            for key in sessionDetailStates.keys {
                updateSessionDetailState(sessionKey: key, isLoading: sessionDetailStates[key]?.isLoading ?? false)
            }
        } else {
            AppLog.info("Watch skipped detail snapshot rebuild during agent selection")
        }
        AppLog.info("Watch snapshots rebuilt agents=\(agentsListState.rows.count) sessions=\(sessionListState.rows.count) selectedAgentId=\(watchStore.selectedAgentId)")
    }

    // ─── Ariadne's Thread [AT-0124] ─────────────────────
    // What: Freeze the Watch agent navigation state after the first non-empty startup snapshot.
    // Why:  The Agents screen is static navigation for this launch; later iPhone agent snapshots update cache only and must not rewrite visible paging rows.
    // Date: 2026-06-09
    // Related: [AT-0123] WatchHomeView.AgentsPage, [AT-0122] app→AppModel.loadGatewayAgentsOnceForLaunch
    // ─────────────────────────────────────────────────────
    private func publishAgentNavigationState(source: String) {
        let nextAgents = watchStore.agentOrder.compactMap { watchStore.agentsById[$0] }
        if gatewayAgents != nextAgents {
            gatewayAgents = nextAgents
            AppLog.info("Watch published gatewayAgents count=\(nextAgents.count) source=\(source)")
        }
        let nextState = buildAgentsListState()
        if agentsListState != nextState {
            agentsListState = nextState
            AppLog.info("Watch published AgentsListState rows=\(nextState.rows.count) source=\(source)")
        } else {
            AppLog.info("Watch skipped identical AgentsListState publish source=\(source)")
        }
        if !watchStore.agentOrder.isEmpty, !agentNavigationStateFrozen {
            agentNavigationStateFrozen = true
            AppLog.info("Watch froze agent navigation state rows=\(nextState.rows.count) source=\(source)")
        }
    }

    private func buildAgentsListState() -> AgentsListState {
        let rows = agentRowsForDisplay().map { agent in
            AgentListRowState(
                id: agent.id,
                name: agent.name,
                emoji: agent.emoji,
                subtitle: agent.subtitle,
                modelLabel: agent.modelLabel,
                isDefault: agent.isDefault
            )
        }
        return AgentsListState(rows: rows)
    }

    // ─── Ariadne's Thread [AT-0111] ─────────────────────
    // What: Prefer the latest visible session text in Watch session list rows.
    // Why:  Session cards must show the newest session text on the first line instead of using the title first.
    // Date: 2026-06-09
    // Related: [AT-0101] WatchHomeView.GatewaySessionsListPage
    // ─────────────────────────────────────────────────────
    private func buildSessionListState(isLoading: Bool) -> SessionListState {
        let ids = watchStore.sessionOrderByAgentId[mainAgentId] ?? []
        let rows = ids.compactMap { id -> SessionListRowState? in
            guard let row = watchStore.sessionsById[id] else { return nil }
            return SessionListRowState(
                id: row.id,
                title: row.title,
                preview: latestSessionText(for: row.id) ?? row.preview,
                updatedAt: row.updatedAt,
                hasActiveJob: gatewayActiveJob(for: row.id) != nil
            )
        }
        return SessionListState(rows: rows, selectedAgentId: mainAgentId, isLoading: isLoading)
    }

    private func latestSessionText(for sessionKey: String) -> String? {
        let loadedMessageText = watchStore.messagesBySessionKey[sessionKey]?
            .last?
            .text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let loadedMessageText, !loadedMessageText.isEmpty {
            return loadedMessageText
        }
        let liveJob = gatewayJobs[sessionKey]?.first
        let liveJobText = (liveJob?.resultText ?? liveJob?.transcript)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let liveJobText, !liveJobText.isEmpty {
            return liveJobText
        }
        return nil
    }

    private func updateSessionDetailState(sessionKey: String, isLoading: Bool) {
        let row = watchStore.sessionsById[sessionKey]
        sessionDetailStates[sessionKey] = SessionDetailState(
            sessionKey: sessionKey,
            title: row?.title ?? "Session",
            updatedAt: row?.updatedAt,
            messages: watchStore.messagesBySessionKey[sessionKey] ?? [],
            liveJobs: gatewayJobs[sessionKey] ?? [],
            isLoading: isLoading
        )
        AppLog.info("Watch detailStateUpdated sessionKey=\(sessionKey) messages=\(sessionDetailStates[sessionKey]?.messages.count ?? 0) liveJobs=\(sessionDetailStates[sessionKey]?.liveJobs.count ?? 0) isLoading=\(isLoading)")
    }

    func sessionDetailState(for sessionKey: String) -> SessionDetailState {
        if let state = sessionDetailStates[sessionKey] {
            return state
        }
        let row = watchStore.sessionsById[sessionKey]
        return SessionDetailState(
            sessionKey: sessionKey,
            title: row?.title ?? "Session",
            updatedAt: row?.updatedAt,
            messages: watchStore.messagesBySessionKey[sessionKey] ?? [],
            liveJobs: gatewayJobs[sessionKey] ?? [],
            isLoading: false
        )
    }

    var selectedAgentIdForSync: String {
        mainAgentId
    }

    var knownGatewayAgentIdsForSync: [String] {
        watchStore.agentOrder
    }

    private func agentRowsForDisplay() -> [WatchAgentRow] {
        let rows = watchStore.agentOrder.compactMap { watchStore.agentsById[$0] }
        guard !rows.isEmpty else {
            return [WatchGatewayAgent(id: "main", name: "Main Actor", emoji: "🎯", subtitle: "Default agent", modelLabel: nil, isDefault: true)]
        }
        return rows
    }

    private func syncLegacySessionIndexFromStore() {
        let orderedIds = watchStore.sessionOrderByAgentId
            .keys
            .sorted()
            .flatMap { watchStore.sessionOrderByAgentId[$0] ?? [] }
        gatewaySessions = orderedIds.compactMap { id in
            guard let row = watchStore.sessionsById[id] else { return nil }
            return WatchGatewaySession(id: row.id, title: row.title, preview: row.preview, updatedAt: row.updatedAt, messages: [])
        }
    }

    private static func loadCachedGatewaySessions() -> [WatchGatewaySession] {
        guard let data = UserDefaults.standard.data(forKey: PairingLocalCache.gatewaySessionsKey) else { return [] }
        do {
            let cached = try JSONDecoder().decode([WatchGatewaySession].self, from: data)
            let normalized = normalizeGatewaySessions(cached)
            if normalized.contains(where: { !$0.messages.isEmpty }) {
                saveCachedGatewaySessionIndexOnly(Self.gatewaySessionIndex(from: normalized), source: "loadCachedGatewaySessions")
            }
            AppLog.info("Watch loaded cached gateway sessions count=\(normalized.count) rawCount=\(cached.count)")
            return normalized
        } catch {
            AppLog.error("Watch cached gateway sessions decode failed: \(error.localizedDescription)")
            return []
        }
    }

    private func saveCachedGatewaySessions() {
        do {
            let orderedIds = watchStore.sessionOrderByAgentId
                .keys
                .sorted()
                .flatMap { watchStore.sessionOrderByAgentId[$0] ?? [] }
            let sessions = orderedIds.compactMap { id -> WatchGatewaySession? in
                guard let row = watchStore.sessionsById[id] else { return nil }
                return WatchGatewaySession(
                    id: row.id,
                    title: row.title,
                    preview: row.preview,
                    updatedAt: row.updatedAt,
                    messages: []
                )
            }
            let data = try JSONEncoder().encode(sessions)
            Self.replaceCachedGatewaySessionsData(data)
            AppLog.info("Watch saved cached gateway store sessionIndexOnly sessions=\(sessions.count) inMemoryMessageSessions=\(watchStore.messagesBySessionKey.count)")
        } catch {
            AppLog.error("Watch cached gateway sessions encode failed: \(error.localizedDescription)")
        }
    }

    private static func saveCachedGatewaySessionIndexOnly(_ sessions: [WatchGatewaySession], source: String) {
        do {
            let data = try JSONEncoder().encode(sessions)
            replaceCachedGatewaySessionsData(data)
            AppLog.info("Watch compacted cached gateway sessions sessionIndexOnly sessions=\(sessions.count) bytes=\(data.count) source=\(source)")
        } catch {
            AppLog.error("Watch compact cached gateway sessions encode failed source=\(source): \(error.localizedDescription)")
        }
    }

    private static func replaceCachedGatewaySessionsData(_ data: Data) {
        UserDefaults.standard.removeObject(forKey: PairingLocalCache.gatewaySessionsKey)
        UserDefaults.standard.set(data, forKey: PairingLocalCache.gatewaySessionsKey)
    }

    // ─── Ariadne's Thread [AT-0078] ─────────────────────
    // What: Cache gateway agents and selected agent locally on Watch.
    // Why:  After app reinstall/update the Watch should show all agents immediately, not only the fallback Main Actor while waiting for iPhone.
    // Date: 2026-06-08
    // Related: [AT-0069] WatchAppModel.requestMissingGatewaySessionsForSessionScreen
    // ─────────────────────────────────────────────────────
    private static func loadCachedGatewayAgents() -> (agents: [WatchGatewayAgent], selectedAgentId: String) {
        let selected = UserDefaults.standard.string(forKey: PairingLocalCache.selectedAgentIdKey) ?? "main"
        guard let data = UserDefaults.standard.data(forKey: PairingLocalCache.gatewayAgentsKey) else {
            return ([], selected)
        }
        do {
            let agents = try JSONDecoder().decode([WatchGatewayAgent].self, from: data)
            let normalized = normalizeGatewayAgents(agents)
            AppLog.info("Watch loaded cached gateway agents count=\(normalized.count) rawCount=\(agents.count) selectedAgentId=\(selected)")
            return (normalized, selected)
        } catch {
            AppLog.error("Watch cached gateway agents decode failed: \(error.localizedDescription)")
            return ([], selected)
        }
    }

    private func saveCachedGatewayAgents() {
        do {
            let agents = watchStore.agentOrder.compactMap { watchStore.agentsById[$0] }
            let data = try JSONEncoder().encode(agents)
            UserDefaults.standard.set(data, forKey: PairingLocalCache.gatewayAgentsKey)
            UserDefaults.standard.set(mainAgentId, forKey: PairingLocalCache.selectedAgentIdKey)
            AppLog.info("Watch saved cached gateway agents count=\(agents.count) mainAgentId=\(mainAgentId)")
        } catch {
            AppLog.error("Watch cached gateway agents encode failed: \(error.localizedDescription)")
        }
    }

    // ─── Ariadne's Thread [AT-0093] ─────────────────────
    // What: Persist selectedAgentId without rewriting the published gatewayAgents array.
    // Why:  Selected-agent-only deltas arrive while Agents List is mounted; touching gatewayAgents there still crashes watchOS with signal 6.
    // Date: 2026-06-08
    // Related: [AT-0085] WatchAppModel.mergeGatewayAgentDelta, [AT-0091] app→WatchConnectivityPhoneService.publishAgents
    // ─────────────────────────────────────────────────────
    private func saveSelectedGatewayAgentId() {
        UserDefaults.standard.set(mainAgentId, forKey: PairingLocalCache.selectedAgentIdKey)
        AppLog.info("Watch saved selected gateway agent id mainAgentId=\(mainAgentId)")
    }

    // ─── Ariadne's Thread [AT-0081] ─────────────────────
    // What: Normalize gateway agents before publishing them into SwiftUI lists.
    // Why:  Duplicate agent ids from iPhone/cached payloads can crash watchOS List/ForEach with signal 6.
    // Date: 2026-06-08
    // Related: [AT-0078] WatchAppModel.loadCachedGatewayAgents, WatchHomeView.AgentsPage
    // ─────────────────────────────────────────────────────
    private static func normalizeGatewayAgents(_ agents: [WatchGatewayAgent]) -> [WatchGatewayAgent] {
        var byId: [String: WatchGatewayAgent] = [:]
        for agent in agents {
            let id = agent.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            byId[id] = WatchGatewayAgent(
                id: id,
                name: agent.name,
                emoji: agent.emoji,
                subtitle: agent.subtitle,
                modelLabel: agent.modelLabel,
                isDefault: agent.isDefault
            )
        }
        let mains = byId.values.filter { $0.id == "main" }
        let rest = byId.values
            .filter { $0.id != "main" }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return mains + rest
    }

    // ─── Ariadne's Thread [AT-0085] ─────────────────────
    // What: Merge incoming gateway agents by id without replacing cached Watch rows.
    // Why:  Agents List/ForEach must stay cache-first while iPhone returns only missing agent deltas.
    // Date: 2026-06-08
    // Related: [AT-0083] shared→WatchEnvelope.knownGatewayAgentIds, [AT-0084] WatchConnectivityWatchService.requestMissingGatewaySessions
    // ─────────────────────────────────────────────────────
    private func mergeGatewayAgentDelta(_ incoming: [WatchGatewayAgent]) {
        let normalizedIncoming = Self.normalizeGatewayAgents(incoming)
        guard !normalizedIncoming.isEmpty else {
            AppLog.info("Watch gateway agents merge skipped: empty delta")
            return
        }
        let existingIds = Set(gatewayAgents.map(\.id))
        let missing = normalizedIncoming.filter { !existingIds.contains($0.id) }
        guard !missing.isEmpty else {
            AppLog.info("Watch gateway agents merge skipped: no missing agents incoming=\(normalizedIncoming.count) cached=\(gatewayAgents.count)")
            return
        }
        gatewayAgents = Self.normalizeGatewayAgents(gatewayAgents + missing)
        saveCachedGatewayAgents()
        AppLog.info("Watch merged gateway agent delta missing=\(missing.count) incoming=\(normalizedIncoming.count) cached=\(gatewayAgents.count)")
    }

    private static func normalizeGatewaySessions(_ sessions: [WatchGatewaySession]) -> [WatchGatewaySession] {
        var byId: [String: WatchGatewaySession] = [:]
        for session in sessions {
            let normalized = WatchGatewaySession(
                id: session.id,
                title: session.title,
                preview: session.preview,
                updatedAt: session.updatedAt,
                messages: normalizeMessages(session.messages)
            )
            if let existing = byId[session.id] {
                byId[session.id] = mergeGatewaySessionValues(existing: existing, incoming: normalized)
            } else {
                byId[session.id] = normalized
            }
        }
        return byId.values.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    private static func gatewaySessionIndex(from sessions: [WatchGatewaySession]) -> [WatchGatewaySession] {
        normalizeGatewaySessions(sessions).map { session in
            WatchGatewaySession(
                id: session.id,
                title: session.title,
                preview: session.preview,
                updatedAt: session.updatedAt,
                messages: []
            )
        }
    }

    private static func gatewayMessagesBySessionKey(from sessions: [WatchGatewaySession]) -> [String: [WatchHistoryMessage]] {
        var result: [String: [WatchHistoryMessage]] = [:]
        for session in normalizeGatewaySessions(sessions) where !session.messages.isEmpty {
            result[session.id] = session.messages
        }
        return result
    }

    private static func normalizeMessages(_ messages: [WatchHistoryMessage]) -> [WatchHistoryMessage] {
        var seen: Set<String> = []
        var result: [WatchHistoryMessage] = []
        for message in messages where !seen.contains(message.id) {
            seen.insert(message.id)
            result.append(WatchHistoryMessage(id: message.id, isUser: message.isUser, text: String(message.text.prefix(cachedMessageTextLimit))))
        }
        return result
    }

    private static func mergeGatewaySessionValues(existing: WatchGatewaySession, incoming: WatchGatewaySession) -> WatchGatewaySession {
        var seen: Set<String> = []
        var messages: [WatchHistoryMessage] = []
        for message in existing.messages + incoming.messages where !seen.contains(message.id) {
            seen.insert(message.id)
            messages.append(message)
        }
        return WatchGatewaySession(
            id: incoming.id,
            title: incoming.title,
            preview: incoming.preview ?? existing.preview,
            updatedAt: incoming.updatedAt ?? existing.updatedAt,
            messages: messages
        )
    }

    // ─── Ariadne's Thread [AT-0096] ─────────────────────
    // What: Merge gateway message deltas into a per-session store without touching the session index.
    // Why:  Existing GatewaySessionsListPage rows must stay stable while GatewaySessionPage receives message updates.
    // Date: 2026-06-08
    // Related: [AT-0094] WatchAppModel.gatewayMessagesBySessionKey, [AT-0095] WatchHomeView.GatewaySessionPage
    // ─────────────────────────────────────────────────────
    private func mergeGatewayMessages(from incoming: [WatchGatewaySession]) {
        var changedSessions = 0
        var changedMessages = 0
        for session in incoming {
            let messages = Self.normalizeMessages(session.messages)
            guard !messages.isEmpty else { continue }
            let existing = gatewayMessagesBySessionKey[session.id] ?? []
            var seen = Set(existing.map(\.id))
            var merged = existing
            var added = 0
            for message in messages where !seen.contains(message.id) {
                seen.insert(message.id)
                merged.append(message)
                added += 1
            }
            guard added > 0 else { continue }
            gatewayMessagesBySessionKey[session.id] = merged
            changedSessions += 1
            changedMessages += added
        }
        if changedMessages > 0 {
            AppLog.info("Watch merged gateway message delta sessions=\(changedSessions) messages=\(changedMessages)")
        }
    }

    /// Sticky gateway pairing: once connected, stays paired until iPhone sends revokeGatewayPairing (Disconnect).
    var isPaired: Bool {
        UserDefaults.standard.bool(forKey: PairingLocalCache.wasConnectedKey) || pairing.phase == .connected
    }

    private func restorePairingFromLocalCache() {
        guard UserDefaults.standard.bool(forKey: PairingLocalCache.wasConnectedKey) else {
            AppLog.info("Watch pairing local cache miss; phase=\(pairing.phase.rawValue)")
            return
        }
        let url = UserDefaults.standard.string(forKey: PairingLocalCache.gatewayURLKey)
        let deviceId = UserDefaults.standard.string(forKey: PairingLocalCache.deviceIdKey)
        pairing = PairingSnapshot(
            phase: .connected,
            gatewayURL: url,
            message: "Syncing with iPhone…",
            deviceId: deviceId
        )
        AppLog.info("Watch restored pairing from local cache gatewayURL=\(url ?? "nil"); awaiting iPhone sync")
    }

    /// True when local cache says we were gateway-connected; used to ignore stale WCSession applicationContext.
    func shouldSkipStaleApplicationContext() -> Bool {
        let skip = UserDefaults.standard.bool(forKey: PairingLocalCache.wasConnectedKey)
        if skip {
            AppLog.info("Watch shouldSkipStaleApplicationContext=true (sticky pairing cache)")
        }
        return skip
    }

    private func shouldAcceptRemotePairing(
        _ remote: PairingSnapshot,
        envelopeKind: WatchMessageKind,
        revokeGatewayPairing: Bool
    ) -> Bool {
        let sticky = UserDefaults.standard.bool(forKey: PairingLocalCache.wasConnectedKey)
        switch remote.phase {
        case .connected:
            return true
        case .connecting, .waitingForApproval:
            if sticky || pairing.phase == .connected {
                AppLog.info("Watch ignored pairing phase=\(remote.phase.rawValue) from kind=\(envelopeKind.rawValue) (sticky paired)")
                return false
            }
            return true
        case .needsSetupCode, .failed:
            guard revokeGatewayPairing else {
                if sticky {
                    AppLog.info("Watch ignored pairing downgrade to \(remote.phase.rawValue) from kind=\(envelopeKind.rawValue) without revokeGatewayPairing")
                }
                return !sticky
            }
            AppLog.info("Watch accepting pairing revoke to \(remote.phase.rawValue) from kind=\(envelopeKind.rawValue)")
            return true
        }
    }

    private func persistPairingFromPhone(
        _ snapshot: PairingSnapshot,
        envelopeKind: WatchMessageKind,
        revokeGatewayPairing: Bool
    ) {
        guard shouldAcceptRemotePairing(snapshot, envelopeKind: envelopeKind, revokeGatewayPairing: revokeGatewayPairing) else { return }
        pairing = snapshot
        switch snapshot.phase {
        case .connected:
            UserDefaults.standard.set(true, forKey: PairingLocalCache.wasConnectedKey)
            if let url = snapshot.gatewayURL {
                UserDefaults.standard.set(url, forKey: PairingLocalCache.gatewayURLKey)
            }
            if let deviceId = snapshot.deviceId {
                UserDefaults.standard.set(deviceId, forKey: PairingLocalCache.deviceIdKey)
            }
            AppLog.info("Watch persisted sticky connected pairing to local cache")
        case .needsSetupCode, .failed:
            guard revokeGatewayPairing else {
                AppLog.info("Watch kept sticky cache despite phase=\(snapshot.phase.rawValue) (no revoke)")
                return
            }
            UserDefaults.standard.removeObject(forKey: PairingLocalCache.wasConnectedKey)
            UserDefaults.standard.removeObject(forKey: PairingLocalCache.gatewayURLKey)
            UserDefaults.standard.removeObject(forKey: PairingLocalCache.deviceIdKey)
            AppLog.info("Watch cleared sticky pairing cache and gateway identity after explicit revoke phase=\(snapshot.phase.rawValue)")
        case .connecting, .waitingForApproval:
            AppLog.info("Watch pairing intermediate phase=\(snapshot.phase.rawValue); sticky cache unchanged")
        }
    }

    private func applyRemotePairingAndTts(from envelope: WatchEnvelope) {
        let revoke = envelope.revokeGatewayPairing == true
        if let remote = envelope.pairing {
            persistPairingFromPhone(remote, envelopeKind: envelope.kind, revokeGatewayPairing: revoke)
        }
        if revoke {
            AppLog.info("Watch received explicit gateway pairing revoke")
            clearSessionMessageAgentUsageDataAfterPairingRevoke()
        }
        applyGlobalTts(envelope.ttsEnabled)
        applyTtsLanguage(envelope.ttsLanguage)
        applyHapticType(envelope.hapticType)
        applyTtsRate(envelope.ttsRate)
        WatchGatewayCredentialStore.save(
            gatewayURL: envelope.pairing?.gatewayURL,
            operatorToken: envelope.gatewayOperatorToken,
            operatorScopes: envelope.gatewayOperatorScopes
        )
    }

    // ─── Ariadne's Thread [AT-0030] ─────────────────────
    // What: Clear mirrored sessions, messages, agents, and usage when iPhone revokes pairing.
    // Why:  After devices are unpaired, Watch must not keep stale sessions, messages, usage, agents, jobs, or local caches.
    // Date: 2026-06-06
    // Related: app→AppModel disconnect, [AT-0029] app→AppModel mergeAndPublishWatchGatewaySessions
    // ─────────────────────────────────────────────────────
    private func clearSessionMessageAgentUsageDataAfterPairingRevoke() {
        watchStore = WatchStore()
        gatewaySessions = []
        gatewayMessagesBySessionKey = [:]
        UserDefaults.standard.removeObject(forKey: PairingLocalCache.gatewaySessionsKey)
        UserDefaults.standard.removeObject(forKey: PairingLocalCache.gatewayAgentsKey)
        UserDefaults.standard.removeObject(forKey: PairingLocalCache.selectedAgentIdKey)
        gatewayJobs = [:]
        gatewayMutedKeys = []
        usage = nil
        gatewayAgents = []
        selectedAgentId = "main"
        mainAgentId = "main"
        agentNavigationStateFrozen = false
        WatchGatewayCredentialStore.clear()
        sessions = [WatchSession(sessionKey: "agent:main:main")]
        currentIndex = 0
        horizontalIndex = 2
        pendingJobIds = []
        jobSession = [:]
        spokenJobIds = []
        recordingSessionId = nil
        jobGatewayKey = [:]
        gatewayRecordingKey = nil
        recordingJobId = nil
        statusHint = nil
        rebuildWatchSnapshots()
        AppLog.info("Watch cleared sessions/messages/agents/usage after pairing revoke")
    }

    var isRecording: Bool { recorder.isRecording }

    var currentSession: WatchSession? {
        sessions.indices.contains(currentIndex) ? sessions[currentIndex] : nil
    }

    /// Agents to show on the Agents page. Falls back to Main Actor when the iPhone has not pushed any yet.
    var agentsForDisplay: [WatchGatewayAgent] {
        if gatewayAgents.isEmpty {
            return [WatchGatewayAgent(
                id: "main",
                name: "Main Actor",
                emoji: "🎯",
                subtitle: "Default agent",
                modelLabel: nil,
                isDefault: true
            )]
        }
        return gatewayAgents
    }

    /// Main Actor first, then other agents by name (mirrors iPhone).
    var sortedAgentsForDisplay: [WatchGatewayAgent] {
        let list = agentsForDisplay.map { agent -> WatchGatewayAgent in
            if agent.id == "main" {
                return WatchGatewayAgent(
                    id: agent.id,
                    name: "Main Actor",
                    emoji: agent.emoji ?? "🎯",
                    subtitle: agent.subtitle,
                    modelLabel: agent.modelLabel,
                    isDefault: agent.isDefault
                )
            }
            return agent
        }
        let mains = list.filter { $0.id == "main" }
        let rest = list.filter { $0.id != "main" }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return mains + rest
    }

    /// Gateway session pages for the active agent only (`agent:<selectedAgentId>:…`).
    var filteredGatewaySessions: [WatchGatewaySession] {
        gatewaySessions.filter { sessionAgentId(from: $0.id) == mainAgentId }
    }

    private func sessionAgentId(from sessionKey: String) -> String {
        let parts = sessionKey.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "agent" else { return "main" }
        let id = String(parts[1])
        return id.isEmpty ? "main" : id
    }

    func hasActiveGatewayJob(for sessionKey: String) -> Bool {
        gatewayActiveJob(for: sessionKey) != nil
    }

    /// Agent row for `selectedAgentId` (same name/emoji as on the Agents page).
    var selectedAgentDisplay: WatchGatewayAgent? {
        sortedAgentsForDisplay.first { $0.id == mainAgentId }
    }

    /// Emoji for the active agent (same as Agents page card).
    func selectedAgentEmojiSymbol() -> String {
        if let agent = selectedAgentDisplay {
            return agentEmoji(for: agent)
        }
        return mainAgentId == "main" ? "🎯" : "🤖"
    }

    /// Display name for the active agent (Main Actor for `main`).
    func selectedAgentTitleName() -> String {
        if let agent = selectedAgentDisplay {
            return agentDisplayName(for: agent)
        }
        return mainAgentId == "main" ? "Main Actor" : mainAgentId
    }

    private func agentDisplayName(for agent: WatchGatewayAgent) -> String {
        agent.id == "main" ? "Main Actor" : agent.name
    }

    private func agentEmoji(for agent: WatchGatewayAgent) -> String {
        if let emoji = agent.emoji?.trimmingCharacters(in: .whitespacesAndNewlines), !emoji.isEmpty {
            return emoji
        }
        return agent.id == "main" ? "🎯" : "🤖"
    }

    private func newSessionKey(for agentId: String? = nil) -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "agent:\(agentId ?? mainAgentId):\(token)"
    }

    // ─── Ariadne's Thread [AT-0004] ─────────────────────
    // What: Start a fresh Watch live session whenever an agent is selected.
    // Why:  The Agents page is an explicit "new conversation with this agent" entry point; the extra
    //       swipe-up new-session page should appear only after the current session has sent a turn.
    // Date: 2026-06-05
    // Related: WatchAppModel.finishRecordingAndSend, WatchAppModel.ensureTopNewSessionPageAfterSend
    // ─────────────────────────────────────────────────────
    /// User picked an agent on the Watch — open a fresh live session for that agent and sync selection to the iPhone.
    func selectAgent(_ agentId: String) {
        pendingAgentTapId = nil
        mainAgentId = agentId
        selectedAgentId = agentId
        sessions = [WatchSession(sessionKey: newSessionKey(for: agentId))]
        currentIndex = 0
        horizontalIndex = 2
        statusHint = nil
        UserDefaults.standard.set(mainAgentId, forKey: PairingLocalCache.selectedAgentIdKey)
        AppLog.info("Watch selectAgent id=\(agentId); started fresh live session key=\(sessions[0].sessionKey); sending to iPhone")
        bridge.sendCommand(WatchEnvelope(kind: .selectAgent, text: agentId))
    }

    private func applySelectedAgentFromIPhone(_ agentId: String) {
        let previous = selectedAgentId
        mainAgentId = agentId
        watchStore.selectedAgentId = agentId
        selectedAgentIdDidChange(agentId)
        saveSelectedGatewayAgentId()
        guard !recorder.isRecording, sessions.allSatisfy(\.isEmpty) else {
            rebuildWatchSnapshots()
            AppLog.info("Watch selectedAgentId=\(agentId) from iPhone; kept live sessions previous=\(previous)")
            return
        }
        sessions = [WatchSession(sessionKey: newSessionKey(for: agentId))]
        currentIndex = 0
        rebuildWatchSnapshots()
        AppLog.info("Watch selectedAgentId=\(agentId) from iPhone; reset empty live session key=\(sessions[0].sessionKey) previous=\(previous)")
    }

    private func mergeGatewaySessionDelta(_ incoming: [WatchGatewaySession]) {
        guard !incoming.isEmpty else { return }
        let normalizedIncoming = Self.normalizeGatewaySessions(incoming)
        let fingerprint = Self.gatewaySessionsFingerprint(normalizedIncoming)
        guard fingerprint != lastGatewaySessionsFingerprint else {
            AppLog.info("Watch skipped duplicate gatewaySessions delta fingerprint=\(fingerprint)")
            return
        }
        lastGatewaySessionsFingerprint = fingerprint
        mergeGatewayMessages(from: normalizedIncoming)
        let existingIds = Set(gatewaySessions.map(\.id))
        let missingSessions = normalizedIncoming.filter { !existingIds.contains($0.id) }
        guard !missingSessions.isEmpty else {
            AppLog.info("Watch gateway session delta updated messages only incoming=\(normalizedIncoming.count) cachedSessions=\(gatewaySessions.count)")
            return
        }
        gatewaySessions = Self.gatewaySessionIndex(from: gatewaySessions + missingSessions)
        saveCachedGatewaySessions()
        AppLog.info("Watch merged gateway session index delta missingSessions=\(missingSessions.count) incoming=\(normalizedIncoming.count) cachedSessions=\(gatewaySessions.count)")
    }

    // ─── Ariadne's Thread [AT-0075] ─────────────────────
    // What: Replace the gateway session index while keeping messages in the separate store.
    // Why:  Sessions list refreshes contain titles/previews first; replacing directly must not erase already loaded message history on Watch.
    // Date: 2026-06-08
    // Related: [AT-0069] WatchAppModel.requestMissingGatewaySessionsForSessionScreen, [AT-0096] WatchAppModel.mergeGatewayMessages
    // ─────────────────────────────────────────────────────
    private func replaceGatewaySessionsPreservingMessages(_ incoming: [WatchGatewaySession]) {
        let normalizedIncoming = Self.normalizeGatewaySessions(incoming)
        mergeGatewayMessages(from: normalizedIncoming)
        gatewaySessions = Self.gatewaySessionIndex(from: normalizedIncoming)
        saveCachedGatewaySessions()
    }

    private static func gatewaySessionsFingerprint(_ sessions: [WatchGatewaySession]) -> String {
        sessions
            .map { "\($0.id):\($0.messages.map(\.id).joined(separator: ","))" }
            .joined(separator: "|")
    }

    // ─── Ariadne's Thread [AT-0069] ─────────────────────
    // What: Ask iPhone for only gateway sessions/messages missing from the Watch cache.
    // Why:  The Sessions screen should keep local sessions/messages and avoid refetching history the Watch already has.
    // Date: 2026-06-08
    // Related: [AT-0029] app→AppModel.mergeAndPublishWatchGatewaySessions, [AT-0070] app→AppModel.publishMissingGatewaySessionsToWatch
    // ─────────────────────────────────────────────────────
    func requestMissingGatewaySessionsForSessionScreen() {
        send(.sessionsPageAppeared(agentId: mainAgentId))
    }

    // ─── Ariadne's Thread [AT-0079] ─────────────────────
    // What: Request missing messages only for the session page the user opens.
    // Why:  Fetching histories for every cached session at once overloaded watchOS and crashed during gatewaySessions merge.
    // Date: 2026-06-08
    // Related: [AT-0074] app→AppModel.publishMissingGatewaySessionsToWatch, [AT-0095] WatchHomeView.GatewaySessionPage
    // ─────────────────────────────────────────────────────
    func requestMissingGatewayMessagesForSession(_ sessionKey: String) {
        send(.sessionDetailAppeared(sessionKey: sessionKey))
    }

    func gatewayMessages(for sessionKey: String) -> [WatchHistoryMessage] {
        gatewayMessagesBySessionKey[sessionKey] ?? []
    }

    func applyEnvelope(_ data: Data) {
        guard let envelope = try? JSONDecoder().decode(WatchEnvelope.self, from: data) else {
            AppLog.error("Watch failed to decode envelope")
            return
        }
        send(.transportEnvelope(envelope, source: "legacy-applyEnvelope"))
    }

    /// Remote "Tap to listen" from the iPhone: open a fresh session page and begin recording on the Watch.
    /// Effective only while the Watch app is active on screen — watchOS cannot start the microphone in the background.
    private func handleRemoteStartListening() {
        guard isPaired else {
            statusHint = "Pair on iPhone first."
            AppLog.error("Watch remote startListening blocked: not paired")
            return
        }
        guard !recorder.isRecording else {
            AppLog.info("Watch remote startListening ignored: already recording")
            return
        }
        // Jump to the top empty "new session" page so the recording opens a fresh conversation.
        if sessions.indices.contains(0), sessions[0].isEmpty {
            currentIndex = 0
        }
        Task { await beginRecording() }
    }

    /// Applies the iPhone's global TTS switch. Turning it off also stops any reply currently being spoken.
    private func applyGlobalTts(_ enabled: Bool?) {
        guard let enabled else { return }
        let wasEnabled = globalTtsEnabled
        globalTtsEnabled = enabled
        AppLog.info("Watch globalTtsEnabled=\(enabled) (was \(wasEnabled)); Voice On button \(enabled ? "visible" : "hidden")")
        if wasEnabled && !enabled {
            SpeechPlaybackService.shared.stop()
            AppLog.info("Watch global TTS disabled by iPhone; stopped active speech")
        }
    }

    /// Applies the iPhone's chosen speech language.
    private func applyTtsLanguage(_ language: String?) {
        guard let language, !language.isEmpty, language != globalTtsLanguage else { return }
        globalTtsLanguage = language
        AppLog.info("Watch TTS language set to \(language) by iPhone")
    }

    // ─── Ariadne's Thread [AT-0009] ─────────────────────
    // What: Apply iPhone-controlled Watch haptic and speech-rate preferences.
    // Why:  Record-button feedback and spoken reply speed are global voice settings owned by the iPhone app.
    // Date: 2026-06-05
    // Related: [AT-0007] WatchEnvelope haptic/rate fields, [AT-0008] AppModel voice settings
    // ─────────────────────────────────────────────────────
    private func applyTtsRate(_ rate: Double?) {
        guard let rate, rate > 0, rate != globalTtsRate else { return }
        globalTtsRate = rate
        AppLog.info("Watch TTS rate set to \(rate) by iPhone")
    }

    private func applyHapticType(_ raw: String?) {
        guard let raw, let parsed = WatchHapticType(rawValue: raw), parsed != hapticType else { return }
        hapticType = parsed
        AppLog.info("Watch record haptic set to \(parsed.rawValue) by iPhone")
    }

    func playRecordHaptic() {
        guard let wkType = Self.wkHaptic(for: hapticType) else {
            AppLog.info("Watch record haptic skipped (off)")
            return
        }
        WKInterfaceDevice.current().play(wkType)
        AppLog.info("Watch played record haptic=\(hapticType.rawValue)")
    }

    private static func wkHaptic(for type: WatchHapticType) -> WKHapticType? {
        switch type {
        case .off: return nil
        case .notification: return .notification
        case .directionUp: return .directionUp
        case .directionDown: return .directionDown
        case .success: return .success
        case .failure: return .failure
        case .retry: return .retry
        case .start: return .start
        case .stop: return .stop
        case .click: return .click
        }
    }

    /// Per-session mute toggle. Muting a session that is currently speaking stops it immediately.
    func toggleMute(sessionId: UUID) {
        guard let si = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[si].muted.toggle()
        let muted = sessions[si].muted
        if muted { SpeechPlaybackService.shared.stop() }
        AppLog.info("Watch session mute toggled sessionId=\(sessionId) muted=\(muted)")
    }

    /// Push-to-talk: first tap starts recording on the Watch, second tap stops and ships the audio to the iPhone.
    /// The recording always belongs to the session currently shown on screen.
    func toggleRecord() {
        guard isPaired else {
            statusHint = "Pair on iPhone first."
            AppLog.error("Watch toggleRecord blocked: not paired")
            return
        }
        if isRecording {
            Task { await finishRecordingAndSend() }
        } else {
            // Guard against accidental starts: when the user swipes between sessions on the vertical stack, watchOS can
            // register the swipe's release as a tap on the large Speak button. If a switch just happened, ignore this
            // start so navigating sessions never auto-starts a recording. Stopping is never guarded.
            if let switchedAt = lastSessionSwitchAt, Date().timeIntervalSince(switchedAt) < sessionSwitchTapGuardInterval {
                AppLog.info("Watch toggleRecord ignored: within \(sessionSwitchTapGuardInterval)s of a session switch (treated as swipe tail)")
                return
            }
            Task { await beginRecording() }
        }
    }

    private func beginRecording() async {
        FlowLog.function(step: 3, side: .watch, flow: "audio-record", name: "WatchAppModel.beginRecording")
        AppLog.info("Watch beginRecording — requesting mic permission")
        let granted = await recorder.ensurePermission()
        guard granted else {
            statusHint = "Allow Microphone in Watch Settings."
            AppLog.error("Watch beginRecording blocked: mic denied")
            return
        }
        guard sessions.indices.contains(currentIndex) else {
            statusHint = "Recording failed"
            AppLog.error("Watch beginRecording blocked: current session missing index=\(currentIndex)")
            return
        }
        // ─── Ariadne's Thread [AT-0108] ─────────────────────
        // What: Move selected-agent live session creation from Agents List tap to Speak.
        // Why:  Mutating the live TabView session array during an Agents List tap crashes watchOS with signal 6.
        // Date: 2026-06-08
        // Related: [AT-0123] WatchHomeView.AgentsPage, [AT-0124] WatchAppModel.publishAgentNavigationState
        // ─────────────────────────────────────────────────────
        let selectedAgentForRecording = pendingAgentTapId ?? mainAgentId
        if sessionAgentId(from: sessions[currentIndex].sessionKey) != selectedAgentForRecording {
            if sessions[currentIndex].isEmpty {
                sessions[currentIndex] = WatchSession(sessionKey: newSessionKey(for: selectedAgentForRecording))
            } else {
                sessions.insert(WatchSession(sessionKey: newSessionKey(for: selectedAgentForRecording)), at: 0)
                currentIndex = 0
            }
            mainAgentId = selectedAgentForRecording
            UserDefaults.standard.set(mainAgentId, forKey: PairingLocalCache.selectedAgentIdKey)
            pendingAgentTapId = nil
            AppLog.info("Watch prepared selected-agent live session on Speak selectedAgentId=\(selectedAgentForRecording) sessionKey=\(sessions[currentIndex].sessionKey)")
        }
        beginFileRecording(session: sessions[currentIndex], gatewayKey: nil)
    }

    // ─── Ariadne's Thread [AT-0026] ─────────────────────
    // What: Record one local Watch audio file and transfer it to iPhone.
    // Why:  OpenClaw batch audio understanding expects an attachment, not Watch PCM chunks.
    // Date: 2026-06-06
    // Related: app→WatchAudioRecorder, app→WatchConnectivityWatchService sendAudio
    // ─────────────────────────────────────────────────────
    private func beginFileRecording(session: WatchSession, gatewayKey: String?) {
        do {
            try recorder.startRecording()
            playRecordHaptic()
            let job = VoiceJob(
                status: .listening,
                statusDetail: "Listening…",
                gatewaySessionKey: session.sessionKey,
                agentId: sessionAgentId(from: session.sessionKey)
            )
            pendingJobIds.insert(job.id)
            markJobUpdate(job.id, source: "record-start")
            if let gatewayKey {
                jobGatewayKey[job.id] = gatewayKey
                gatewayJobs[gatewayKey, default: []].insert(job, at: 0)
            } else if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                jobSession[job.id] = session.id
                sessions[index].jobs.insert(job, at: 0)
                ensureTopNewSessionPageAfterSend(currentSessionId: session.id)
            }
            recordingJobId = job.id
            recordingSessionId = gatewayKey == nil ? session.id : nil
            gatewayRecordingKey = gatewayKey
            statusHint = nil
            objectWillChange.send()
            AppLog.info("Watch file recording started jobId=\(job.id) sessionKey=\(session.sessionKey) gatewayKey=\(gatewayKey ?? "nil")")
        } catch {
            statusHint = "Mic error"
            AppLog.error("Watch file startRecording failed: \(error.localizedDescription)")
        }
    }

    /// Adds the swipe-up "new session" page only after a real turn has been sent from the current session.
    private func ensureTopNewSessionPageAfterSend(currentSessionId: UUID) {
        guard let sentIndex = sessions.firstIndex(where: { $0.id == currentSessionId }) else {
            AppLog.error("Watch ensureTopNewSessionPageAfterSend failed: sent session missing id=\(currentSessionId)")
            return
        }
        guard !sessions[sentIndex].isEmpty else {
            AppLog.info("Watch skipped new-session page: sent session still empty id=\(currentSessionId)")
            return
        }
        if sessions.indices.contains(0), sessions[0].isEmpty {
            AppLog.info("Watch new-session page already available; sentIndex=\(sentIndex) sessions=\(sessions.count)")
            return
        }
        sessions.insert(WatchSession(sessionKey: newSessionKey()), at: 0)
        currentIndex = sentIndex + 1
        AppLog.info("Watch added swipe-up new-session page after send; currentIndex=\(currentIndex) sessions=\(sessions.count)")
    }

    private func finishRecordingAndSend() async {
        if recorder.isRecording {
            guard let savedAudio = finishFileRecording() else { return }
            sendSavedAudioFileToIPhoneBot(savedAudio)
            return
        }
        statusHint = "Recording failed"
        recordingSessionId = nil
        AppLog.error("Watch finishRecording blocked: file recorder is not active")
        objectWillChange.send()
    }

    // ─── Ariadne's Thread [AT-0037] ─────────────────────
    // What: Split Watch audio into a save stage and a separate iPhone/bot send stage.
    // Why:  The system must not treat "recording stopped" and "file sent" as one operation.
    // Date: 2026-06-07
    // Related: [AT-0026] WatchAppModel beginFileRecording, [AT-0024] WatchConnectivityWatchService sendAudio
    // ─────────────────────────────────────────────────────
    private struct SavedWatchAudioFile {
        let jobId: UUID
        let fileURL: URL
        let sessionKey: String
        let bytes: Int
    }

    private func finishFileRecording() -> SavedWatchAudioFile? {
        guard let jobId = recordingJobId else {
            _ = recorder.stopRecording()
            AppLog.error("Watch file finishRecording: job id missing")
            return nil
        }
        guard let fileURL = recorder.stopRecording() else {
            FlowLog.started(step: 4, side: .watch, flow: "audio-save", detail: "jobId=\(jobId)")
            FlowLog.result(step: 4, side: .watch, flow: "audio-save", success: false, detail: "recording file missing jobId=\(jobId)")
            FlowLog.finished(step: 4, side: .watch, flow: "audio-save")
            updateDirectJob(jobId: jobId, status: .failed, errorMessage: "Recording file is missing.", statusDetail: nil, completedAt: Date())
            AppLog.error("Watch file finishRecording: recorder returned nil URL jobId=\(jobId)")
            return nil
        }
        let fileBytes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? -1
        FlowLog.started(step: 4, side: .watch, flow: "audio-save", detail: "jobId=\(jobId)")
        FlowLog.function(step: 4, side: .watch, flow: "audio-save", name: "WatchAppModel.finishFileRecording")
        FlowLog.progress(step: 4, side: .watch, flow: "audio-save", detail: "saved on Watch path=\(fileURL.path) bytes=\(fileBytes)")
        FlowLog.result(step: 4, side: .watch, flow: "audio-save", success: fileBytes > 0, detail: "fileExists=\(FileManager.default.fileExists(atPath: fileURL.path)) bytes=\(fileBytes)")
        FlowLog.finished(step: 4, side: .watch, flow: "audio-save")
        playRecordHaptic()
        let sessionKey = gatewayRecordingKey
            ?? recordingSessionId.flatMap { sid in sessions.first(where: { $0.id == sid })?.sessionKey }
            ?? "agent:\(mainAgentId):main"
        AppLog.info("Watch audio file saved jobId=\(jobId) sessionKey=\(sessionKey) file=\(fileURL.lastPathComponent) bytes=\(fileBytes)")
        return SavedWatchAudioFile(jobId: jobId, fileURL: fileURL, sessionKey: sessionKey, bytes: fileBytes)
    }

    private func sendSavedAudioFileToIPhoneBot(_ savedAudio: SavedWatchAudioFile) {
        updateDirectJob(jobId: savedAudio.jobId, status: .sending, statusDetail: "Sending…")
        let queuedForIPhone = bridge.sendAudio(
            fileURL: savedAudio.fileURL,
            jobId: savedAudio.jobId,
            sessionKey: savedAudio.sessionKey
        )
        if queuedForIPhone {
            try? FileManager.default.removeItem(at: savedAudio.fileURL)
            AppLog.info("Watch iPhone relay audio send requested jobId=\(savedAudio.jobId) sessionKey=\(savedAudio.sessionKey) file=\(savedAudio.fileURL.lastPathComponent) bytes=\(savedAudio.bytes)")
        } else if WatchNetworkPathMonitor.shared.internetAvailable {
            Task { await sendSavedAudioFileDirectToGateway(savedAudio) }
            AppLog.info("Watch direct WSS fallback started jobId=\(savedAudio.jobId) sessionKey=\(savedAudio.sessionKey) file=\(savedAudio.fileURL.lastPathComponent) bytes=\(savedAudio.bytes)")
        } else {
            updateDirectJob(
                jobId: savedAudio.jobId,
                status: .failed,
                errorMessage: "iPhone relay is unavailable and Watch has no direct internet.",
                statusDetail: nil,
                completedAt: Date()
            )
            try? FileManager.default.removeItem(at: savedAudio.fileURL)
            AppLog.error("Watch audio send failed: relay queue unavailable and direct internet unavailable jobId=\(savedAudio.jobId)")
        }
        recordingJobId = nil
        recordingSessionId = nil
        gatewayRecordingKey = nil
        statusHint = nil
        objectWillChange.send()
    }

    private func sendSavedAudioFileDirectToGateway(_ savedAudio: SavedWatchAudioFile) async {
        do {
            let audioData = try Data(contentsOf: savedAudio.fileURL)
            FlowLog.started(step: 5, side: .watch, flow: "audio-send-server", detail: "jobId=\(savedAudio.jobId) sessionKey=\(savedAudio.sessionKey) file=\(savedAudio.fileURL.lastPathComponent) bytes=\(audioData.count) path=direct-watch-wss")
            FlowLog.function(step: 5, side: .watch, flow: "audio-send-server", name: "WatchGatewayDirectClient.runAudioAttachment")
            let reply = try await WatchGatewayDirectClient.shared.runAudioAttachment(
                audioData: audioData,
                fileName: savedAudio.fileURL.lastPathComponent,
                mimeType: "audio/mp4",
                sessionKey: savedAudio.sessionKey,
                idempotencyKey: savedAudio.jobId.uuidString,
                onProgress: { detail in
                    let jobId = savedAudio.jobId
                    Task { @MainActor in
                        FlowLog.progress(step: 5, side: .watch, flow: "audio-send-server", detail: "direct-wss jobId=\(savedAudio.jobId) \(detail)")
                        WatchAppModel.shared.updateDirectJob(jobId: jobId, status: .sending, statusDetail: detail)
                    }
                }
            )
            updateDirectJob(jobId: savedAudio.jobId, status: .done, resultText: reply, statusDetail: nil, completedAt: Date())
            FlowLog.result(step: 5, side: .watch, flow: "audio-send-server", success: true, detail: "direct WSS sent jobId=\(savedAudio.jobId)")
            FlowLog.finished(step: 5, side: .watch, flow: "audio-send-server")
            FlowLog.started(step: 6, side: .watch, flow: "server-response", detail: "jobId=\(savedAudio.jobId) status=done")
            FlowLog.result(step: 6, side: .watch, flow: "server-response", success: true, detail: "received=yes replyLength=\(reply.count)")
            FlowLog.finished(step: 6, side: .watch, flow: "server-response")
            AppLog.info("Watch direct WSS audio reply done jobId=\(savedAudio.jobId) replyLength=\(reply.count)")
        } catch {
            updateDirectJob(jobId: savedAudio.jobId, status: .failed, errorMessage: error.localizedDescription, statusDetail: nil, completedAt: Date())
            FlowLog.result(step: 5, side: .watch, flow: "audio-send-server", success: false, detail: "direct WSS failed jobId=\(savedAudio.jobId) error=\(error.localizedDescription)")
            FlowLog.finished(step: 5, side: .watch, flow: "audio-send-server")
            FlowLog.started(step: 6, side: .watch, flow: "server-response", detail: "jobId=\(savedAudio.jobId) status=failed")
            FlowLog.result(step: 6, side: .watch, flow: "server-response", success: false, detail: "received=no error=\(error.localizedDescription)")
            FlowLog.finished(step: 6, side: .watch, flow: "server-response")
            AppLog.error("Watch direct WSS audio failed jobId=\(savedAudio.jobId): \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: savedAudio.fileURL)
    }

    func activeJobsForSync() -> [VoiceJob] {
        let local = sessions.flatMap(\.jobs).filter { !$0.status.isTerminal && $0.status != .idle && $0.status != .listening }
        let gateway = gatewayJobs.values.flatMap { $0 }.filter { !$0.status.isTerminal && $0.status != .idle && $0.status != .listening }
        let all = local + gateway
        var seen: Set<UUID> = []
        return all.filter { job in
            guard !seen.contains(job.id) else { return false }
            seen.insert(job.id)
            return job.gatewaySessionKey?.isEmpty == false
        }
    }

    // ─── Ariadne's Thread [AT-0059] ─────────────────────
    // What: Poll iPhone every 5 seconds for active async audio jobs, capped at 300 seconds.
    // Why:  iPhone relay now creates a backend job and answers short Watch-driven status checks instead of holding WSS open.
    // Date: 2026-06-08
    // Related: [AT-0024] watch→WatchConnectivityWatchService.requestSync, [AT-0066] app→AppModel.handleWatchMessage
    // ─────────────────────────────────────────────────────
    func tickJobStatusWatchdog() {
        let now = Date()
        for job in activeJobsForSync() {
            let pollStartedAt = jobPollingStartedAt[job.id] ?? job.createdAt
            let age = now.timeIntervalSince(pollStartedAt)
            guard age >= 5 else { continue }
            guard age <= 300 else {
                markJobForRetry(job)
                continue
            }
            if let lastSync = jobLastWatchdogSyncAt[job.id], now.timeIntervalSince(lastSync) < 5 { continue }
            jobLastWatchdogSyncAt[job.id] = now
            AppLog.info("Watch job poll requestJobStatus jobId=\(job.id) serverJobId=\(job.gatewayRunId ?? "nil") status=\(job.status.rawValue) detail=\(job.statusDetail ?? "nil") age=\(Int(age))s")
            WatchConnectivityWatchService.shared.requestJobStatus(job)
        }
    }

    // ─── Ariadne's Thread [AT-0067] ─────────────────────
    // What: Convert expired async audio jobs into a Retry button and force a one-job iPhone poll when tapped.
    // Why:  If 300 seconds was not enough, the user can manually ask iPhone to check the same serverJobId again.
    // Date: 2026-06-08
    // Related: [AT-0059] WatchAppModel.tickJobStatusWatchdog, [AT-0066] app→AppModel.handleWatchMessage
    // ─────────────────────────────────────────────────────
    private func markJobForRetry(_ job: VoiceJob) {
        updateRetryState(
            jobId: job.id,
            status: .failed,
            statusDetail: "Retry",
            errorMessage: "Processing timed out.",
            completedAt: Date(),
            updateSource: "poll-timeout"
        )
        AppLog.info("Watch job polling stopped after 300s jobId=\(job.id) status=\(job.status.rawValue) detail=\(job.statusDetail ?? "nil") serverJobId=\(job.gatewayRunId ?? "nil")")
    }

    func retryJob(_ job: VoiceJob) {
        var pollingJob = job
        pollingJob.status = .running
        pollingJob.statusDetail = "Processing…"
        pollingJob.errorMessage = nil
        pollingJob.completedAt = nil
        updateRetryState(
            jobId: job.id,
            status: .running,
            statusDetail: "Processing…",
            errorMessage: nil,
            completedAt: nil,
            updateSource: "retry"
        )
        jobPollingStartedAt[job.id] = Date()
        jobLastWatchdogSyncAt[job.id] = Date()
        AppLog.info("Watch retry requested jobId=\(job.id) serverJobId=\(job.gatewayRunId ?? "nil")")
        WatchConnectivityWatchService.shared.requestJobStatus(pollingJob)
    }

    private func updateRetryState(
        jobId: UUID,
        status: JobStatus,
        statusDetail: String?,
        errorMessage: String?,
        completedAt: Date?,
        updateSource: String
    ) {
        if let key = jobGatewayKey[jobId], var arr = gatewayJobs[key], let index = arr.firstIndex(where: { $0.id == jobId }) {
            arr[index].status = status
            arr[index].statusDetail = statusDetail
            arr[index].errorMessage = errorMessage
            arr[index].completedAt = completedAt
            gatewayJobs[key] = arr
        } else if let sessionId = jobSession[jobId],
                  let si = sessions.firstIndex(where: { $0.id == sessionId }),
                  let ji = sessions[si].jobs.firstIndex(where: { $0.id == jobId }) {
            sessions[si].jobs[ji].status = status
            sessions[si].jobs[ji].statusDetail = statusDetail
            sessions[si].jobs[ji].errorMessage = errorMessage
            sessions[si].jobs[ji].completedAt = completedAt
        } else {
            AppLog.error("Watch retry state update missed jobId=\(jobId) source=\(updateSource)")
            return
        }
        markJobUpdate(jobId, source: updateSource)
        objectWillChange.send()
    }

    private func markJobUpdate(_ jobId: UUID, source: String) {
        jobLastUpdateAt[jobId] = Date()
        AppLog.info("Watch job update timestamp jobId=\(jobId) source=\(source)")
    }

    func cancelRecording() {
        guard recorder.isRecording else { return }
        recorder.cancel()
        if let jobId = recordingJobId {
            updateDirectJob(jobId: jobId, status: .cancelled, statusDetail: nil, completedAt: Date())
        }
        recordingSessionId = nil
        gatewayRecordingKey = nil
        recordingJobId = nil
        statusHint = nil
        objectWillChange.send()
        AppLog.info("Watch cancelled recording")
    }

    // MARK: - Gateway session pages (horizontal)

    /// Live turns the Watch started inside a gateway-session page (newest-first). Read by the gateway page UI.
    func gatewayTurns(for sessionKey: String) -> [VoiceJob] {
        gatewayJobs[sessionKey] ?? []
    }

    /// The in-flight turn for a gateway page, if any (drives the spinner + status inside the Speak button).
    func gatewayActiveJob(for sessionKey: String) -> VoiceJob? {
        gatewayJobs[sessionKey]?.first { !$0.status.isTerminal && $0.status != .idle }
    }

    func gatewayRetryJob(for sessionKey: String) -> VoiceJob? {
        gatewayJobs[sessionKey]?.first { $0.status == .failed && $0.statusDetail == "Retry" }
    }

    /// True while the global recorder is capturing audio destined for this specific gateway session.
    func isRecordingGateway(_ sessionKey: String) -> Bool {
        recorder.isRecording && gatewayRecordingKey == sessionKey
    }

    /// Whether replies for this gateway session are muted on the Watch.
    func isGatewayMuted(_ sessionKey: String) -> Bool {
        gatewayMutedKeys.contains(sessionKey)
    }

    /// Per-session mute for a gateway page. Muting also stops any reply currently being spoken (so it's a "stop" too).
    func toggleGatewayMute(sessionKey: String) {
        if gatewayMutedKeys.contains(sessionKey) {
            gatewayMutedKeys.remove(sessionKey)
            AppLog.info("Watch gateway session unmuted sessionKey=\(sessionKey)")
        } else {
            gatewayMutedKeys.insert(sessionKey)
            SpeechPlaybackService.shared.stop()
            AppLog.info("Watch gateway session muted sessionKey=\(sessionKey); stopped active speech")
        }
    }

    /// Push-to-talk for a gateway session: first tap records, second tap stops and ships the audio tagged with this key.
    func toggleGatewayRecord(sessionKey: String) {
        guard isPaired else {
            statusHint = "Pair on iPhone first."
            AppLog.error("Watch gateway toggleRecord blocked: not paired")
            return
        }
        if isRecording {
            Task { await finishGatewayRecordingAndSend() }
        } else {
            Task { await beginGatewayRecording(sessionKey: sessionKey) }
        }
    }

    private func beginGatewayRecording(sessionKey: String) async {
        AppLog.info("Watch beginGatewayRecording sessionKey=\(sessionKey) — requesting mic permission")
        let granted = await recorder.ensurePermission()
        guard granted else {
            statusHint = "Allow Microphone in Watch Settings."
            AppLog.error("Watch gateway beginRecording blocked: mic denied")
            return
        }
        beginFileRecording(session: WatchSession(sessionKey: sessionKey), gatewayKey: sessionKey)
    }

    private func finishGatewayRecordingAndSend() async {
        if recorder.isRecording {
            _ = finishFileRecording()
            return
        }
        statusHint = "Recording failed"
        gatewayRecordingKey = nil
        objectWillChange.send()
        AppLog.error("Watch gateway finishRecording blocked: file recorder is not active")
    }

    private func updateDirectJob(
        jobId: UUID,
        status: JobStatus,
        transcript: String? = nil,
        resultText: String? = nil,
        errorMessage: String? = nil,
        statusDetail: String?,
        completedAt: Date? = nil
    ) {
        let updated = applyDirectJobUpdate(
            jobId: jobId,
            status: status,
            transcript: transcript,
            resultText: resultText,
            errorMessage: errorMessage,
            statusDetail: statusDetail,
            completedAt: completedAt
        )
        if let updated, updated.status == .done {
            if let key = jobGatewayKey[jobId] {
                speakOnce(updated, muted: isGatewayMuted(key))
            } else if let sessionId = jobSession[jobId], let si = sessions.firstIndex(where: { $0.id == sessionId }) {
                speakOnce(updated, muted: sessions[si].muted)
            }
        }
        objectWillChange.send()
    }

    private func applyDirectJobUpdate(
        jobId: UUID,
        status: JobStatus,
        transcript: String?,
        resultText: String?,
        errorMessage: String?,
        statusDetail: String?,
        completedAt: Date?
    ) -> VoiceJob? {
        if let key = jobGatewayKey[jobId] {
            var arr = gatewayJobs[key] ?? []
            guard let index = arr.firstIndex(where: { $0.id == jobId }) else {
                AppLog.error("Watch direct gateway update missed jobId=\(jobId) sessionKey=\(key)")
                return nil
            }
            guard shouldApplyJobStatus(current: arr[index].status, incoming: status, jobId: jobId, source: "direct-gateway") else {
                return arr[index]
            }
            arr[index].status = status
            if let transcript { arr[index].transcript = transcript }
            if let resultText { arr[index].resultText = resultText }
            if let errorMessage { arr[index].errorMessage = errorMessage }
            arr[index].statusDetail = statusDetail
            if let completedAt { arr[index].completedAt = completedAt }
            gatewayJobs[key] = arr
            if status.isTerminal { pendingJobIds.remove(jobId) }
            markJobUpdate(jobId, source: "direct-gateway")
            AppLog.info("Watch direct gateway job update jobId=\(jobId) status=\(status.rawValue) detail=\(statusDetail ?? "nil") transcriptLength=\(arr[index].transcript?.count ?? 0) replyLength=\(arr[index].resultText?.count ?? 0)")
            return arr[index]
        }

        guard
            let sessionId = jobSession[jobId],
            let si = sessions.firstIndex(where: { $0.id == sessionId }),
            let ji = sessions[si].jobs.firstIndex(where: { $0.id == jobId })
        else {
            AppLog.error("Watch direct local update missed jobId=\(jobId)")
            return nil
        }
        guard shouldApplyJobStatus(current: sessions[si].jobs[ji].status, incoming: status, jobId: jobId, source: "direct-local") else {
            return sessions[si].jobs[ji]
        }
        sessions[si].jobs[ji].status = status
        if let transcript { sessions[si].jobs[ji].transcript = transcript }
        if let resultText { sessions[si].jobs[ji].resultText = resultText }
        if let errorMessage { sessions[si].jobs[ji].errorMessage = errorMessage }
        sessions[si].jobs[ji].statusDetail = statusDetail
        if let completedAt { sessions[si].jobs[ji].completedAt = completedAt }
        if status.isTerminal { pendingJobIds.remove(jobId) }
        markJobUpdate(jobId, source: "direct-local")
        AppLog.info("Watch direct local job update jobId=\(jobId) status=\(status.rawValue) detail=\(statusDetail ?? "nil") transcriptLength=\(sessions[si].jobs[ji].transcript?.count ?? 0) replyLength=\(sessions[si].jobs[ji].resultText?.count ?? 0)")
        return sessions[si].jobs[ji]
    }

    /// Applies an iPhone job update to a gateway-session turn (mirrors the local upsert behavior, but on `gatewayJobs`).
    private func upsertGateway(_ job: VoiceJob, key: String) {
        var arr = gatewayJobs[key] ?? []
        if let ji = arr.firstIndex(where: { $0.id == job.id }) {
            guard shouldApplyJobStatus(current: arr[ji].status, incoming: job.status, jobId: job.id, source: "gateway-snapshot") else {
                return
            }
            arr[ji] = job
        } else {
            arr.insert(job, at: 0)
        }
        gatewayJobs[key] = arr
        markJobUpdate(job.id, source: "gateway-upsert")
        AppLog.info("Watch gateway job update jobId=\(job.id) sessionKey=\(key) status=\(job.status.rawValue) detail=\(job.statusDetail ?? "nil") transcriptLength=\(job.transcript?.count ?? 0) replyLength=\(job.resultText?.count ?? 0) error=\(job.errorMessage ?? "nil")")
        if job.status.isTerminal { pendingJobIds.remove(job.id) }

        switch job.status {
        case .done:
            statusHint = nil
            speakOnce(job, muted: isGatewayMuted(key))
        case .failed, .cancelled, .sending, .running, .idle, .listening:
            break
        }
    }

    // ─── Ariadne's Thread [AT-0049] ─────────────────────
    // What: Restore gateway job-to-session mapping from iPhone job snapshots.
    // Why:  Pending result reconciliation can finish after Watch relaunch, when in-memory jobGatewayKey is gone.
    // Date: 2026-06-07
    // Related: [AT-0048] shared→VoiceJob.gatewaySessionKey, [AT-0046] app→AppModel.resumePendingAudioJobs
    // ─────────────────────────────────────────────────────
    private func upsert(_ job: VoiceJob) {
        if let si = sessions.firstIndex(where: { $0.jobs.contains(where: { $0.id == job.id }) }) {
            jobSession[job.id] = sessions[si].id
            if let ji = sessions[si].jobs.firstIndex(where: { $0.id == job.id }) {
                guard shouldApplyJobStatus(current: sessions[si].jobs[ji].status, incoming: job.status, jobId: job.id, source: "live-session-snapshot") else {
                    return
                }
                sessions[si].jobs[ji] = job
            } else {
                sessions[si].jobs.insert(job, at: 0)
            }
            if job.status.isTerminal {
                pendingJobIds.remove(job.id)
            }
            markJobUpdate(job.id, source: "live-upsert")
            AppLog.info("Watch upsert: updated existing live session jobId=\(job.id) status=\(job.status.rawValue) detail=\(job.statusDetail ?? "nil")")
            switch job.status {
            case .done:
                statusHint = nil
                logStep7DisplayReply(job: job, sessionIndex: si)
                speakOnce(job, muted: sessions[si].muted)
            case .failed:
                logStep7DisplayReply(job: job, sessionIndex: si)
            case .cancelled, .sending, .running, .idle, .listening:
                break
            }
            return
        }
        // Turns started on a gateway-session page are tracked separately and never touch the local vertical sessions.
        if let key = jobGatewayKey[job.id] {
            upsertGateway(job, key: key)
            return
        }
        if let key = job.gatewaySessionKey, !key.isEmpty {
            jobGatewayKey[job.id] = key
            upsertGateway(job, key: key)
            AppLog.info("Watch upsert: attached iPhone job update to gateway session jobId=\(job.id) sessionKey=\(key)")
            return
        }
        // Resolve which local session this job belongs to. Primary source is the in-memory jobSession map, but that map
        // can be lost if the Watch app was suspended/relaunched between sending the audio and the iPhone's reply. In
        // that case fall back to locating the job by id inside the existing sessions (the job row itself survives in the
        // sessions array) and rebuild the mapping, so a finished reply is never dropped and stuck on "Sending…".
        let resolvedIndex: Int?
        if let sessionId = jobSession[job.id], let si = sessions.firstIndex(where: { $0.id == sessionId }) {
            resolvedIndex = si
        } else if let si = sessions.firstIndex(where: { $0.jobs.contains(where: { $0.id == job.id }) }) {
            jobSession[job.id] = sessions[si].id
            AppLog.info("Watch upsert: recovered session mapping for jobId=\(job.id) via existing session row")
            resolvedIndex = si
        } else {
            resolvedIndex = nil
        }

        guard let si = resolvedIndex else {
            AppLog.info("Watch upsert: job has no known session jobId=\(job.id); ignoring")
            return
        }
        if let ji = sessions[si].jobs.firstIndex(where: { $0.id == job.id }) {
            guard shouldApplyJobStatus(current: sessions[si].jobs[ji].status, incoming: job.status, jobId: job.id, source: "local-snapshot") else {
                return
            }
            sessions[si].jobs[ji] = job
        } else {
            sessions[si].jobs.insert(job, at: 0)
        }
        if job.status.isTerminal {
            pendingJobIds.remove(job.id)
        }
        markJobUpdate(job.id, source: "local-upsert")

        switch job.status {
        case .done:
            statusHint = nil
            logStep7DisplayReply(job: job, sessionIndex: si)
            speakOnce(job, muted: sessions[si].muted)
        case .failed:
            logStep7DisplayReply(job: job, sessionIndex: si)
        case .cancelled, .sending, .running, .idle, .listening:
            break
        }
    }

    // ─── Ariadne's Thread [AT-0055] ─────────────────────
    // What: Reject stale Watch job status regressions.
    // Why:  Older iPhone snapshots can arrive after newer jobUpdated messages and must not overwrite a completed result.
    // Date: 2026-06-07
    // Related: WatchAppModel.upsert, WatchAppModel.upsertGateway, WatchAppModel.applyDirectJobUpdate
    // ─────────────────────────────────────────────────────
    private func shouldApplyJobStatus(current: JobStatus, incoming: JobStatus, jobId: UUID, source: String) -> Bool {
        if current == .done, incoming != .done {
            AppLog.info("Watch ignored stale job status source=\(source) jobId=\(jobId) current=done incoming=\(incoming.rawValue)")
            return false
        }
        if current.isTerminal, !incoming.isTerminal {
            AppLog.info("Watch ignored non-terminal job status over terminal source=\(source) jobId=\(jobId) current=\(current.rawValue) incoming=\(incoming.rawValue)")
            return false
        }
        return true
    }

    private func logStep6ServerResponse(job: VoiceJob) {
        guard job.status.isTerminal else { return }
        FlowLog.started(step: 6, side: .watch, flow: "server-response", detail: "jobId=\(job.id) status=\(job.status.rawValue)")
        FlowLog.function(step: 6, side: .watch, flow: "server-response", name: "WatchAppModel.applyEnvelope.jobUpdated")
        switch job.status {
        case .done:
            FlowLog.result(
                step: 6,
                side: .watch,
                flow: "server-response",
                success: true,
                detail: "received=yes replyLength=\(job.resultText?.count ?? 0) transcriptLength=\(job.transcript?.count ?? 0)"
            )
        case .failed:
            FlowLog.result(
                step: 6,
                side: .watch,
                flow: "server-response",
                success: false,
                detail: "received=no error=\(job.errorMessage ?? "unknown") failureSource=\(job.failureSource ?? "nil") elapsedSinceSend=\(job.elapsedSinceSend ?? -1) elapsedSinceLastWSFrame=\(job.elapsedSinceLastWSFrame ?? -1) elapsedSinceWorking=\(job.elapsedSinceWorking ?? -1) runId=\(job.gatewayRunId ?? "nil") wsCloseCode=\(job.wsCloseCode ?? "nil") backendErrorCode=\(job.backendErrorCode ?? "nil")"
            )
        case .cancelled:
            FlowLog.result(step: 6, side: .watch, flow: "server-response", success: false, detail: "received=no reason=cancelled")
        default:
            break
        }
        FlowLog.finished(step: 6, side: .watch, flow: "server-response")
    }

    // ─── Ariadne's Thread [AT-0062] ─────────────────────
    // What: Treat failed jobs with non-empty reply text as displayable replies.
    // Why:  A transport/parser failure should not hide a backend reply that was already recovered into the job.
    // Date: 2026-06-08
    // Related: [AT-0061] app→AppModel.recoverWatchAudioReplyFromHistory
    // ─────────────────────────────────────────────────────
    private func logStep7DisplayReply(job: VoiceJob, sessionIndex: Int) {
        FlowLog.started(step: 7, side: .watch, flow: "display-reply", detail: "jobId=\(job.id) sessionIndex=\(sessionIndex)")
        FlowLog.function(step: 7, side: .watch, flow: "display-reply", name: "WatchAppModel.upsert")
        if let reply = job.resultText, !reply.isEmpty {
            FlowLog.result(step: 7, side: .watch, flow: "display-reply", success: true, detail: "showing replyLength=\(reply.count)")
        } else if job.status == .failed {
            FlowLog.result(step: 7, side: .watch, flow: "display-reply", success: false, detail: "showing error=\(job.errorMessage ?? "unknown")")
        } else {
            FlowLog.result(step: 7, side: .watch, flow: "display-reply", success: false, detail: "nothing to display status=\(job.status.rawValue)")
        }
        FlowLog.finished(step: 7, side: .watch, flow: "display-reply")
    }

    // ─── Ariadne's Thread [AT-0119] ─────────────────────
    // What: Expose manual Watch TTS playback for a single bot message.
    // Why:  Session message cards need to replay exactly the tapped assistant text on demand.
    // Date: 2026-06-09
    // Related: [AT-0062] WatchAppModel.speakOnce, [AT-0120] WatchHomeView.BotMessageCard
    // ─────────────────────────────────────────────────────
    func speakMessageText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        SpeechPlaybackService.shared.speak(trimmed, language: globalTtsLanguage, rateMultiplier: globalTtsRate)
        AppLog.info("Watch TTS manual message playback length=\(trimmed.count)")
    }

    /// Speaks the reply exactly once per job, letting it read to the end without restarting.
    /// Each reply is "handled" once; if voice is off globally or this session is muted, it is silently skipped.
    private func speakOnce(_ job: VoiceJob, muted: Bool) {
        guard !spokenJobIds.contains(job.id), let text = job.resultText, !text.isEmpty else { return }
        spokenJobIds.insert(job.id)
        guard globalTtsEnabled, !muted else {
            AppLog.info("Watch TTS skipped jobId=\(job.id) globalEnabled=\(globalTtsEnabled) muted=\(muted)")
            return
        }
        SpeechPlaybackService.shared.speak(text, language: globalTtsLanguage, rateMultiplier: globalTtsRate)
    }
}
