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
        // Route-aware capture on the Watch: when Bluetooth HFP is allowed the system records from connected Bluetooth
        // headphones (e.g. AirPods) when present, and automatically falls back to the built-in Watch microphone
        // when no headset is connected. We never force the built-in mic, so the fallback is fully automatic.
        // The Bluetooth-input option only exists on watchOS 11.0+, so it is added behind a runtime availability check;
        // on watchOS 10 the recorder simply uses the built-in mic (unchanged previous behavior).
        var options: AVAudioSession.CategoryOptions = [.duckOthers]
        if #available(watchOS 11.0, *) {
            #if compiler(>=6.2)
            options.insert(.allowBluetoothHFP)
            #else
            options.insert(.allowBluetooth)
            #endif
        }
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

    /// Logs the resolved input/output ports so we can confirm whether headphones or the built-in Watch mic is in use.
    private func logCurrentAudioRoute(session: AVAudioSession, context: String) {
        let route = session.currentRoute
        let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let available = (session.availableInputs ?? []).map { $0.portType.rawValue }.joined(separator: ",")
        let usingHeadphoneMic = route.inputs.contains { $0.portType == .bluetoothHFP || $0.portType == .headsetMic }
        AppLog.info("[\(context)] audio route inputs=[\(inputs)] outputs=[\(outputs)] available=[\(available)] usingHeadphoneMic=\(usingHeadphoneMic)")
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
