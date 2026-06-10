import AVFoundation
import Combine
import Foundation

@MainActor
final class WatchAudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var meterLevel: Double = 0

    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private var meterTask: Task<Void, Never>?

    func ensurePermission() async -> Bool {
        let status = AVAudioApplication.shared.recordPermission
        switch status {
        case .granted:
            AppLog.info("Watch mic permission already granted")
            return true
        case .undetermined:
            AppLog.info("Watch mic permission undetermined - requesting")
            return await AVAudioApplication.requestRecordPermission()
        default:
            AppLog.error("Watch mic permission denied status=\(status.rawValue)")
            return false
        }
    }

    // ─── Ariadne's Thread [AT-0023] ─────────────────────
    // What: Record a complete Watch audio file for OpenClaw media attachment delivery.
    // Why:  OpenClaw tools.media.audio is the boxed batch transcription path for voice notes.
    // Date: 2026-06-06
    // Related: app→WatchConnectivityWatchService sendAudio, app→GatewayJobClient runAudioAttachment
    // ─────────────────────────────────────────────────────
    func startRecording() throws {
        guard !isRecording else { return }

        FlowLog.started(step: 3, side: .watch, flow: "audio-record")
        FlowLog.function(step: 3, side: .watch, flow: "audio-record", name: "WatchAudioRecorder.startRecording")

        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = [.duckOthers]
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        logCurrentAudioRoute(session: session, context: "Watch startRecording")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw NSError(domain: "OpenWatch", code: 20, userInfo: [NSLocalizedDescriptionKey: "Could not start audio recording."])
        }
        self.recorder = recorder
        currentURL = url
        isRecording = true
        meterLevel = 0
        startMetering()
        FlowLog.progress(step: 3, side: .watch, flow: "audio-record", detail: "writing audio file url=\(url.lastPathComponent)")
        AppLog.info("Watch started file audio recording url=\(url.lastPathComponent)")
    }

    func stopRecording() -> URL? {
        guard isRecording, let recorder else { return nil }
        stopMetering()
        recorder.stop()
        isRecording = false
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        FlowLog.finished(step: 3, side: .watch, flow: "audio-record", detail: "url=\(currentURL?.lastPathComponent ?? "nil")")
        AppLog.info("Watch stopped file audio recording url=\(currentURL?.lastPathComponent ?? "nil")")
        return currentURL
    }

    func cancel() {
        stopMetering()
        recorder?.stop()
        if let currentURL {
            try? FileManager.default.removeItem(at: currentURL)
        }
        recorder = nil
        currentURL = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        AppLog.info("Watch cancelled file audio recording")
    }

    // ─── Ariadne's Thread [AT-0143] ─────────────────────
    // What: Poll AVAudioRecorder input meters for the live waveform view.
    // Why:  watchOS has no built-in recording waveform; native metering is the supported signal source.
    // Date: 2026-06-10
    // Related: [AT-0143] RecordingWaveformView
    // ─────────────────────────────────────────────────────
    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { @MainActor in
            while !Task.isCancelled, isRecording {
                updateMeterLevel()
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        AppLog.info("Watch recording meter polling started")
    }

    private func stopMetering() {
        meterTask?.cancel()
        meterTask = nil
        meterLevel = 0
        AppLog.info("Watch recording meter polling stopped")
    }

    private func updateMeterLevel() {
        guard let recorder, isRecording else {
            meterLevel = 0
            return
        }
        recorder.updateMeters()
        let averagePower = recorder.averagePower(forChannel: 0)
        let peakPower = recorder.peakPower(forChannel: 0)
        let power = max(averagePower, peakPower)
        let clamped = max(-45, min(0, power))
        let normalized = Double(pow((clamped + 45) / 45, 1.35))
        if normalized >= meterLevel {
            meterLevel = meterLevel * 0.15 + normalized * 0.85
        } else {
            meterLevel = meterLevel * 0.72 + normalized * 0.28
        }
    }

    private func logCurrentAudioRoute(session: AVAudioSession, context: String) {
        let route = session.currentRoute
        let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let available = (session.availableInputs ?? []).map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        AppLog.info("[\(context)] file audio route inputs=[\(inputs)] outputs=[\(outputs)] available=[\(available)] bluetoothHFPAllowed=false")
    }
}

extension WatchAudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error {
            Task { @MainActor in AppLog.error("Watch file audio recorder encode error: \(error.localizedDescription)") }
        }
    }
}
