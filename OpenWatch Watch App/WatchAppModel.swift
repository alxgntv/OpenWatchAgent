import Combine
import Foundation
import SwiftUI

@MainActor
final class WatchAppModel: ObservableObject {
    static let shared = WatchAppModel()

    @Published var pairing = PairingSnapshot()
    @Published var jobs: [VoiceJob] = []
    @Published var selectedJobId: UUID?
    @Published var statusHint: String?

    private let bridge = WatchConnectivityWatchService.shared
    let recorder = WatchAudioRecorder()
    /// Local jobs the iPhone has not acknowledged yet (Watch just recorded and relayed audio).
    private var pendingJobIds: Set<UUID> = []
    private var recordingJobId: UUID?

    private init() {}

    var isPaired: Bool {
        pairing.phase == .connected
    }

    var isRecording: Bool { recorder.isRecording }

    var activeJob: VoiceJob? {
        jobs.first { !$0.status.isTerminal && $0.status != .idle }
    }

    /// The exchange currently shown on the Watch home screen: the selected job, else the most recent one.
    var latestJob: VoiceJob? {
        if let id = selectedJobId, let job = jobs.first(where: { $0.id == id }) { return job }
        return jobs.first
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
            if let pairing = envelope.pairing { self.pairing = pairing }
            if var jobs = envelope.jobs {
                // Preserve pending local jobs the iPhone has not acknowledged yet (just dictated/relayed).
                for localId in pendingJobIds where !jobs.contains(where: { $0.id == localId }) {
                    if let local = self.jobs.first(where: { $0.id == localId }) {
                        jobs.insert(local, at: 0)
                    }
                }
                self.jobs = jobs
            }
            AppLog.info("Watch jobs snapshot count=\(self.jobs.count)")
        case .jobUpdated:
            if let job = envelope.job { upsert(job) }
        default:
            break
        }
    }

    /// Push-to-talk: first tap starts recording on the Watch, second tap stops and ships the audio to the iPhone.
    func toggleRecord() {
        guard isPaired else {
            statusHint = "Pair on iPhone first."
            AppLog.error("Watch toggleRecord blocked: not paired")
            return
        }
        if recorder.isRecording {
            Task { await finishRecordingAndSend() }
        } else if recordingJobId == nil {
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
            statusHint = "Recording… tap to send."
            objectWillChange.send()
            AppLog.info("Watch recording started")
        } catch {
            statusHint = "Mic error"
            AppLog.error("Watch startRecording failed: \(error.localizedDescription)")
        }
    }

    private func finishRecordingAndSend() async {
        guard let url = recorder.stopRecording() else {
            statusHint = "Recording failed"
            AppLog.error("Watch finishRecording: no file")
            objectWillChange.send()
            return
        }
        objectWillChange.send()

        let job = VoiceJob(status: .sending, statusDetail: "Sending…")
        pendingJobIds.insert(job.id)
        recordingJobId = nil
        selectedJobId = job.id
        upsert(job)

        bridge.sendAudio(fileURL: url, jobId: job.id)
        statusHint = "Sending…"
        AppLog.info("Watch sent audio jobId=\(job.id)")
    }

    /// Explicitly start a brand-new chat session. Until this is called, every recording stays in the current session.
    func startNewSession() {
        bridge.sendCommand(WatchEnvelope(kind: .newSession))
        jobs.removeAll()
        selectedJobId = nil
        pendingJobIds.removeAll()
        statusHint = "New session"
        AppLog.info("Watch requested new session")
    }

    func cancelActiveJob() {
        if recorder.isRecording {
            recorder.cancel()
            recordingJobId = nil
            statusHint = "Cancelled"
            objectWillChange.send()
            AppLog.info("Watch cancelled recording")
            return
        }
        guard let job = activeJob else { return }
        pendingJobIds.remove(job.id)
        bridge.sendCommand(WatchEnvelope(kind: .cancelJob, jobId: job.id))
        statusHint = "Cancelled"
        AppLog.info("Watch cancelActiveJob jobId=\(job.id)")
    }

    private func upsert(_ job: VoiceJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
        if job.status.isTerminal {
            pendingJobIds.remove(job.id)
        }
        // Keep the home-screen hint in sync with iPhone-driven progress so it never sticks on "Sending…".
        if job.id == selectedJobId {
            switch job.status {
            case .sending, .running:
                statusHint = "Working…"
            case .done:
                statusHint = nil
                SpeechPlaybackService.shared.speak(job.resultText ?? "")
            case .failed:
                statusHint = job.errorMessage ?? "Failed"
            case .cancelled:
                statusHint = "Cancelled"
            case .idle, .listening:
                break
            }
        }
    }
}
