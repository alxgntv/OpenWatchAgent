import AVFoundation
import Combine

/// Records the user's voice ON THE WATCH to an audio file.
/// watchOS does not expose the Speech framework, so the Watch only captures audio; the iPhone transcribes it.
@MainActor
final class WatchAudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false

    private var recorder: AVAudioRecorder?
    private var currentURL: URL?

    func ensurePermission() async -> Bool {
        let status = AVAudioApplication.shared.recordPermission
        switch status {
        case .granted:
            AppLog.info("Watch mic permission already granted")
            return true
        case .undetermined:
            AppLog.info("Watch mic permission undetermined — requesting")
            return await AVAudioApplication.requestRecordPermission()
        default:
            AppLog.error("Watch mic permission denied status=\(status.rawValue)")
            return false
        }
    }

    func startRecording() throws {
        guard !isRecording else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

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
        guard recorder.record() else {
            throw NSError(domain: "OpenWatch", code: 20, userInfo: [NSLocalizedDescriptionKey: "Could not start audio recording."])
        }
        self.recorder = recorder
        currentURL = url
        isRecording = true
        AppLog.info("Watch started audio recording url=\(url.lastPathComponent)")
    }

    /// Stops recording and returns the recorded file URL.
    func stopRecording() -> URL? {
        guard isRecording, let recorder else { return nil }
        recorder.stop()
        isRecording = false
        let url = currentURL
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        AppLog.info("Watch stopped audio recording url=\(url?.lastPathComponent ?? "nil")")
        return url
    }

    func cancel() {
        if let recorder, isRecording {
            recorder.stop()
        }
        if let url = currentURL {
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        currentURL = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        AppLog.info("Watch cancelled audio recording")
    }
}

extension WatchAudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in AppLog.info("Watch audioRecorderDidFinishRecording success=\(flag)") }
    }
}
