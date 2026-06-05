import Combine
import Foundation
import SwiftUI

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
    /// Defaults to 2 so the app always opens on the main screen. Switching pages stops any active speech.
    @Published var horizontalIndex: Int = 2 {
        didSet {
            guard oldValue != horizontalIndex else { return }
            AppLog.info("Watch horizontal page switched \(oldValue) -> \(horizontalIndex); stopping any active speech")
            SpeechPlaybackService.shared.stop()
        }
    }
    @Published var statusHint: String?
    /// Global "speak replies" switch, mirrored from the iPhone app. Defaults to on until the phone tells us otherwise.
    @Published var globalTtsEnabled: Bool = true
    /// BCP-47 language used to speak replies, mirrored from the iPhone app.
    @Published var globalTtsLanguage: String = "en-US"
    /// Real gateway sessions (with recent history) mirrored from the iPhone — shown as horizontal pages.
    @Published var gatewaySessions: [WatchGatewaySession] = []
    /// Aggregate usage mirrored from the iPhone — shown on the Usage page.
    @Published var usage: WatchUsage?
    /// Configured agents mirrored from the iPhone — shown on the Agents page.
    @Published var gatewayAgents: [WatchGatewayAgent] = []
    /// Active agent id mirrored from the iPhone (filters gateway session pages).
    @Published var selectedAgentId: String = "main"

    private let bridge = WatchConnectivityWatchService.shared
    let recorder = WatchAudioRecorder()
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
    }

    private init() {
        sessions = [WatchSession(sessionKey: "agent:main:main")]
        restorePairingFromLocalCache()
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
            UserDefaults.standard.set(false, forKey: PairingLocalCache.wasConnectedKey)
            AppLog.info("Watch cleared sticky pairing cache after explicit revoke phase=\(snapshot.phase.rawValue)")
        case .connecting, .waitingForApproval:
            AppLog.info("Watch pairing intermediate phase=\(snapshot.phase.rawValue); sticky cache unchanged")
        }
    }

    private func applyRemotePairingAndTts(from envelope: WatchEnvelope) {
        let revoke = envelope.revokeGatewayPairing == true
        if let remote = envelope.pairing {
            persistPairingFromPhone(remote, envelopeKind: envelope.kind, revokeGatewayPairing: revoke)
        }
        applyGlobalTts(envelope.ttsEnabled)
        applyTtsLanguage(envelope.ttsLanguage)
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
        gatewaySessions.filter { sessionAgentId(from: $0.id) == selectedAgentId }
    }

    private func sessionAgentId(from sessionKey: String) -> String {
        let parts = sessionKey.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "agent" else { return "main" }
        let id = String(parts[1])
        return id.isEmpty ? "main" : id
    }

    /// Session count for an agent (shown on the Agents page).
    func sessionCount(forAgentId agentId: String) -> Int {
        gatewaySessions.filter { sessionAgentId(from: $0.id) == agentId }.count
    }

    /// Agent row for `selectedAgentId` (same name/emoji as on the Agents page).
    var selectedAgentDisplay: WatchGatewayAgent? {
        sortedAgentsForDisplay.first { $0.id == selectedAgentId }
    }

    /// Emoji for the active agent (same as Agents page card).
    func selectedAgentEmojiSymbol() -> String {
        if let agent = selectedAgentDisplay {
            return agentEmoji(for: agent)
        }
        return selectedAgentId == "main" ? "🎯" : "🤖"
    }

    /// Display name for the active agent (Main Actor for `main`).
    func selectedAgentTitleName() -> String {
        if let agent = selectedAgentDisplay {
            return agentDisplayName(for: agent)
        }
        return selectedAgentId == "main" ? "Main Actor" : selectedAgentId
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

    private func newSessionKey() -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "agent:\(selectedAgentId):\(token)"
    }

    /// User picked an agent on the Watch — sync selection to the iPhone (which filters sessions and re-pushes).
    func selectAgent(_ agentId: String) {
        selectedAgentId = agentId
        AppLog.info("Watch selectAgent id=\(agentId); sending to iPhone")
        bridge.sendCommand(WatchEnvelope(kind: .selectAgent, text: agentId))
    }

    func applyEnvelope(_ data: Data) {
        guard let envelope = try? JSONDecoder().decode(WatchEnvelope.self, from: data) else {
            AppLog.error("Watch failed to decode envelope")
            return
        }
        AppLog.info("Watch applyEnvelope kind=\(envelope.kind.rawValue) pairingPhase=\(envelope.pairing?.phase.rawValue ?? "unchanged") revoke=\(envelope.revokeGatewayPairing == true)")
        applyRemotePairingAndTts(from: envelope)
        switch envelope.kind {
        case .pairingSnapshot:
            break
        case .jobsSnapshot:
            // Full jobs snapshot (e.g. the iPhone's reply to requestSync). Apply every job so a turn that finished
            // while the Watch was suspended — and whose single jobUpdated push was missed — is reconciled and leaves
            // the "Sending…" state. upsert() recovers the session mapping by job id when needed.
            if let snapshot = envelope.jobs {
                AppLog.info("Watch applying jobsSnapshot count=\(snapshot.count)")
                for job in snapshot { upsert(job) }
            }
        case .jobUpdated:
            if let job = envelope.job { upsert(job) }
        case .startListening:
            if let agentId = envelope.text?.trimmingCharacters(in: .whitespacesAndNewlines), !agentId.isEmpty {
                selectedAgentId = agentId
                AppLog.info("Watch received remote startListening for agentId=\(agentId)")
            } else {
                AppLog.info("Watch received remote startListening (no agent id in envelope)")
            }
            handleRemoteStartListening()
        case .gatewaySessions:
            if let sessions = envelope.gatewaySessions {
                gatewaySessions = sessions
                AppLog.info("Watch received \(sessions.count) gateway sessions from iPhone")
            }
        case .usage:
            if let usage = envelope.usage {
                self.usage = usage
                AppLog.info("Watch received usage agents=\(usage.agentCount) sessions=\(usage.sessionCount) totalTokens=\(usage.totalTokens)")
            }
        case .agents:
            if let agents = envelope.gatewayAgents {
                gatewayAgents = agents
                AppLog.info("Watch received \(agents.count) gateway agents from iPhone")
            }
            if let selected = envelope.selectedAgentId, !selected.isEmpty {
                selectedAgentId = selected
                AppLog.info("Watch selectedAgentId=\(selected) from iPhone")
            }
        default:
            break
        }
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
        if recorder.isRecording {
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
        AppLog.info("Watch beginRecording — requesting mic permission")
        let granted = await recorder.ensurePermission()
        guard granted else {
            statusHint = "Allow Microphone in Watch Settings."
            AppLog.error("Watch beginRecording blocked: mic denied")
            return
        }
        do {
            try recorder.startRecording()
            promoteCurrentEmptyIfNeeded()
            recordingSessionId = sessions.indices.contains(currentIndex) ? sessions[currentIndex].id : nil
            statusHint = nil
            objectWillChange.send()
            AppLog.info("Watch recording started sessionIndex=\(currentIndex)")
        } catch {
            statusHint = "Mic error"
            AppLog.error("Watch startRecording failed: \(error.localizedDescription)")
        }
    }

    /// When recording starts on the top empty "new session" page, turn it into the current session pinned at the bottom
    /// and put a fresh empty page back on top, so the newest conversation is always lowest and swiping up starts a new one.
    private func promoteCurrentEmptyIfNeeded() {
        guard currentIndex == 0, sessions.indices.contains(0), sessions[0].isEmpty else { return }
        let promoted = sessions.remove(at: 0)
        sessions.append(promoted)
        sessions.insert(WatchSession(sessionKey: newSessionKey()), at: 0)
        currentIndex = sessions.count - 1
        AppLog.info("Watch promoted new session to bottom; sessions count=\(sessions.count) currentIndex=\(currentIndex)")
    }

    private func finishRecordingAndSend() async {
        guard let url = recorder.stopRecording() else {
            statusHint = "Recording failed"
            recordingSessionId = nil
            AppLog.error("Watch finishRecording: no file")
            objectWillChange.send()
            return
        }
        objectWillChange.send()

        guard let sid = recordingSessionId, let si = sessions.firstIndex(where: { $0.id == sid }) else {
            statusHint = "Recording failed"
            recordingSessionId = nil
            AppLog.error("Watch finishRecording: target session missing")
            return
        }
        recordingSessionId = nil
        let session = sessions[si]

        // The iPhone serializes all voice turns into a single queue. If another turn is already in flight, show this
        // one as queued right away (instead of "Sending…") so back-to-back recordings across sessions never look stuck;
        // the iPhone later confirms with its own "Queued — waiting…"/progress updates.
        let hasTurnInFlight = hasUnfinishedSentJob(excluding: nil)
        let detail = hasTurnInFlight ? "Queued — waiting…" : "Sending…"
        let job = VoiceJob(status: .sending, statusDetail: detail)
        pendingJobIds.insert(job.id)
        jobSession[job.id] = session.id
        sessions[si].jobs.insert(job, at: 0)

        bridge.sendAudio(fileURL: url, jobId: job.id, sessionKey: session.sessionKey)
        statusHint = nil
        AppLog.info("Watch sent audio jobId=\(job.id) sessionKey=\(session.sessionKey) queued=\(hasTurnInFlight)")
    }

    /// True when any session already has a sent-but-not-finished turn (status .sending/.running). Used to label a new
    /// recording as queued immediately on the Watch, matching the iPhone's serial queue.
    private func hasUnfinishedSentJob(excluding excludedJobId: UUID?) -> Bool {
        for session in sessions {
            for job in session.jobs {
                if let excludedJobId, job.id == excludedJobId { continue }
                if job.status == .sending || job.status == .running {
                    return true
                }
            }
        }
        return false
    }

    func cancelRecording() {
        guard recorder.isRecording else { return }
        recorder.cancel()
        recordingSessionId = nil
        gatewayRecordingKey = nil
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
        if recorder.isRecording {
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
        do {
            try recorder.startRecording()
            gatewayRecordingKey = sessionKey
            recordingSessionId = nil
            statusHint = nil
            objectWillChange.send()
            AppLog.info("Watch gateway recording started sessionKey=\(sessionKey)")
        } catch {
            statusHint = "Mic error"
            AppLog.error("Watch gateway startRecording failed: \(error.localizedDescription)")
        }
    }

    private func finishGatewayRecordingAndSend() async {
        guard let url = recorder.stopRecording() else {
            statusHint = "Recording failed"
            gatewayRecordingKey = nil
            objectWillChange.send()
            AppLog.error("Watch gateway finishRecording: no file")
            return
        }
        objectWillChange.send()

        guard let key = gatewayRecordingKey else {
            statusHint = "Recording failed"
            AppLog.error("Watch gateway finishRecording: target sessionKey missing")
            return
        }
        gatewayRecordingKey = nil

        let job = VoiceJob(status: .sending, statusDetail: "Sending…")
        pendingJobIds.insert(job.id)
        jobGatewayKey[job.id] = key
        gatewayJobs[key, default: []].insert(job, at: 0)

        bridge.sendAudio(fileURL: url, jobId: job.id, sessionKey: key)
        statusHint = nil
        AppLog.info("Watch sent gateway audio jobId=\(job.id) sessionKey=\(key)")
    }

    /// Applies an iPhone job update to a gateway-session turn (mirrors the local upsert behavior, but on `gatewayJobs`).
    private func upsertGateway(_ job: VoiceJob, key: String) {
        var arr = gatewayJobs[key] ?? []
        if let ji = arr.firstIndex(where: { $0.id == job.id }) {
            arr[ji] = job
        } else {
            arr.insert(job, at: 0)
        }
        gatewayJobs[key] = arr
        if job.status.isTerminal { pendingJobIds.remove(job.id) }

        switch job.status {
        case .done:
            statusHint = nil
            speakOnce(job, muted: isGatewayMuted(key))
        case .failed, .cancelled, .sending, .running, .idle, .listening:
            break
        }
    }

    private func upsert(_ job: VoiceJob) {
        // Turns started on a gateway-session page are tracked separately and never touch the local vertical sessions.
        if let key = jobGatewayKey[job.id] {
            upsertGateway(job, key: key)
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
            sessions[si].jobs[ji] = job
        } else {
            sessions[si].jobs.insert(job, at: 0)
        }
        if job.status.isTerminal {
            pendingJobIds.remove(job.id)
        }

        switch job.status {
        case .done:
            statusHint = nil
            speakOnce(job, muted: sessions[si].muted)
        case .failed, .cancelled, .sending, .running, .idle, .listening:
            break
        }
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
        SpeechPlaybackService.shared.speak(text, language: globalTtsLanguage)
    }
}
