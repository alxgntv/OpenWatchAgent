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
    /// Selected HORIZONTAL page (0 = live stack, 1...N = gateway sessions). Switching pages stops any active speech.
    @Published var horizontalIndex: Int = 0 {
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

    private init() {
        sessions = [WatchSession(sessionKey: "agent:main:main")]
    }

    var isPaired: Bool {
        pairing.phase == .connected
    }

    var isRecording: Bool { recorder.isRecording }

    var currentSession: WatchSession? {
        sessions.indices.contains(currentIndex) ? sessions[currentIndex] : nil
    }

    private func newSessionKey() -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "agent:main:\(token)"
    }

    func applyEnvelope(_ data: Data) {
        guard let envelope = try? JSONDecoder().decode(WatchEnvelope.self, from: data) else {
            AppLog.error("Watch failed to decode envelope")
            return
        }
        switch envelope.kind {
        case .pairingSnapshot:
            if let pairing = envelope.pairing {
                self.pairing = pairing
                AppLog.info("Watch pairing phase=\(pairing.phase.rawValue)")
            }
        case .jobsSnapshot:
            // Sessions/history are owned by the Watch now; only the pairing status is taken from the snapshot.
            if let pairing = envelope.pairing { self.pairing = pairing }
            applyGlobalTts(envelope.ttsEnabled)
            applyTtsLanguage(envelope.ttsLanguage)
        case .jobUpdated:
            applyGlobalTts(envelope.ttsEnabled)
            applyTtsLanguage(envelope.ttsLanguage)
            if let job = envelope.job { upsert(job) }
        case .startListening:
            AppLog.info("Watch received remote startListening from iPhone")
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
            statusHint = "Recording… tap to send."
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
        statusHint = "Sending…"
        AppLog.info("Watch sent audio jobId=\(job.id) sessionKey=\(session.sessionKey)")
    }

    func cancelRecording() {
        guard recorder.isRecording else { return }
        recorder.cancel()
        recordingSessionId = nil
        gatewayRecordingKey = nil
        statusHint = "Cancelled"
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
            statusHint = "Recording… tap to send."
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
        statusHint = "Sending…"
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
        case .sending, .running:
            statusHint = job.statusDetail ?? "Working…"
        case .done:
            statusHint = nil
            // Honor the global TTS switch and this gateway session's local mute.
            speakOnce(job, muted: isGatewayMuted(key))
        case .failed:
            statusHint = job.errorMessage ?? "Failed"
        case .cancelled:
            statusHint = "Cancelled"
        case .idle, .listening:
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

        let isCurrent = si == currentIndex
        switch job.status {
        case .sending, .running:
            if isCurrent { statusHint = job.statusDetail ?? "Working…" }
        case .done:
            if isCurrent { statusHint = nil }
            speakOnce(job, muted: sessions[si].muted)
        case .failed:
            if isCurrent { statusHint = job.errorMessage ?? "Failed" }
        case .cancelled:
            if isCurrent { statusHint = "Cancelled" }
        case .idle, .listening:
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
