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
            AppLog.info("Watch session switched \(oldValue) -> \(currentIndex); stopping any active speech")
            SpeechPlaybackService.shared.stop()
        }
    }
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

    var isPaired: Bool {
        pairing.phase == .connected
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

    private func persistPairingFromPhone(_ snapshot: PairingSnapshot) {
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
            AppLog.info("Watch persisted connected pairing to local cache")
        case .needsSetupCode, .failed:
            UserDefaults.standard.set(false, forKey: PairingLocalCache.wasConnectedKey)
            AppLog.info("Watch cleared pairing local cache phase=\(snapshot.phase.rawValue)")
        case .connecting, .waitingForApproval:
            AppLog.info("Watch pairing intermediate phase=\(snapshot.phase.rawValue); local cache unchanged")
        }
    }

    private func applyRemotePairingAndTts(from envelope: WatchEnvelope) {
        if let remote = envelope.pairing {
            persistPairingFromPhone(remote)
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
        AppLog.info("Watch applyEnvelope kind=\(envelope.kind.rawValue) pairingPhase=\(envelope.pairing?.phase.rawValue ?? "unchanged")")
        applyRemotePairingAndTts(from: envelope)
        switch envelope.kind {
        case .pairingSnapshot, .jobsSnapshot:
            break
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
                AppLog.info("Watch received usage sessions=\(usage.sessionCount) totalTokens=\(usage.totalTokens)")
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

        let job = VoiceJob(status: .sending, statusDetail: "Sending…")
        pendingJobIds.insert(job.id)
        jobSession[job.id] = session.id
        sessions[si].jobs.insert(job, at: 0)

        bridge.sendAudio(fileURL: url, jobId: job.id, sessionKey: session.sessionKey)
        statusHint = nil
        AppLog.info("Watch sent audio jobId=\(job.id) sessionKey=\(session.sessionKey)")
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
        guard let sessionId = jobSession[job.id],
              let si = sessions.firstIndex(where: { $0.id == sessionId }) else {
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
