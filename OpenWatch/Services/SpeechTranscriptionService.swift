import AVFoundation
import Combine
import Speech

@MainActor
final class SpeechTranscriptionService: NSObject, ObservableObject {
    @Published private(set) var isListening = false

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    // ─── Ariadne's Thread [AT-0005] ─────────────────────
    // What: Remove the hardcoded Russian recognizer locale.
    // Why:  Voice input can be Russian, English, or another language per session; recognition
    //       must use the system Speech recognizer instead of forcing every audio file through ru-RU.
    // Date: 2026-06-05
    // Related: WatchAudioRecorder, AppModel.processWatchAudioTurn
    // ─────────────────────────────────────────────────────
    private func speechRecognizer(localeIdentifier: String) throws -> SFSpeechRecognizer {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            throw NSError(domain: "OpenWatch", code: 6, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer is unavailable for \(localeIdentifier)."])
        }
        guard recognizer.isAvailable else {
            throw NSError(domain: "OpenWatch", code: 6, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer is unavailable for \(recognizer.locale.identifier)."])
        }
        return recognizer
    }

    func requestPermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        let micStatus = await AVAudioApplication.requestRecordPermission()
        AppLog.info("Speech permission=\(speechStatus) mic=\(micStatus)")
        return speechStatus && micStatus
    }

    /// Uses stored authorization so watch-triggered capture works when iPhone is in the background.
    func ensurePermissions() async -> Bool {
        let speechAuth = SFSpeechRecognizer.authorizationStatus()
        let micAuth = AVAudioApplication.shared.recordPermission
        if speechAuth == .authorized, micAuth == .granted {
            AppLog.info("Speech permissions already granted (background-safe)")
            return true
        }
        if speechAuth == .notDetermined || micAuth == .undetermined {
            AppLog.info("Speech permissions not determined — requesting (requires foreground once)")
            return await requestPermissions()
        }
        AppLog.error("Speech permissions denied speech=\(speechAuth.rawValue) mic=\(micAuth.rawValue)")
        return false
    }

    func startListening() throws {
        guard !isListening else { return }
        recognitionTask?.cancel()
        recognitionTask = nil

        let session = AVAudioSession.sharedInstance()
        // Route-aware input: when headphones (Bluetooth or wired) are connected, the system captures from them
        // automatically; on disconnect it falls back to the built-in mic. We intentionally DO NOT pass
        // `.defaultToSpeaker` here, because forcing the loud speaker overrides any connected headset route.
        // `.allowBluetoothHFP` is the new name (Xcode 26+); `.allowBluetooth` is the same raw value on older Xcode.
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP, .allowAirPlay, .duckOthers]
        #if compiler(>=6.2)
        options.insert(.allowBluetoothHFP)
        #else
        options.insert(.allowBluetooth)
        #endif
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        logCurrentAudioRoute(session: session, context: "iPhone startListening")

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest?.shouldReportPartialResults = true
        guard let recognitionRequest else {
            throw NSError(domain: "OpenWatch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not start speech recognition."])
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isListening = true
        AppLog.info("Started listening for voice command")
    }

    func stopAndTranscribe(localeIdentifier: String) async throws -> String {
        guard isListening else {
            throw NSError(domain: "OpenWatch", code: 2, userInfo: [NSLocalizedDescriptionKey: "Not currently listening."])
        }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        isListening = false

        let speechRecognizer = try speechRecognizer(localeIdentifier: localeIdentifier)
        AppLog.info("Transcribing live audio recognizerLocale=\(speechRecognizer.locale.identifier)")
        return try await withCheckedThrowingContinuation { continuation in
            guard let recognitionRequest else {
                continuation.resume(throwing: NSError(domain: "OpenWatch", code: 3, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable."]))
                return
            }
            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                AppLog.info("Speech transcription completed length=\(text.count)")
                continuation.resume(returning: text)
            }
        }
    }

    /// Logs the resolved input/output ports so we can confirm whether headphones or built-in devices are in use.
    private func logCurrentAudioRoute(session: AVAudioSession, context: String) {
        let route = session.currentRoute
        let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let available = (session.availableInputs ?? []).map { $0.portType.rawValue }.joined(separator: ",")
        let usingHeadphoneMic = route.inputs.contains { Self.headphoneInputPortTypes.contains($0.portType) }
        AppLog.info("[\(context)] audio route inputs=[\(inputs)] outputs=[\(outputs)] available=[\(available)] usingHeadphoneMic=\(usingHeadphoneMic)")
    }

    /// Port types that represent an external headset/headphone microphone (anything that is NOT the built-in mic).
    private static let headphoneInputPortTypes: Set<AVAudioSession.Port> = [
        .bluetoothHFP,
        .headsetMic,
        .usbAudio,
        .carAudio,
        .lineIn,
    ]

    func cancel() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        isListening = false
        AppLog.info("Cancelled speech listening")
    }

    /// Transcribes an audio file recorded on the Apple Watch. The Watch cannot run the Speech framework, so the iPhone does it.
    func transcribeFile(at url: URL, localeIdentifier: String) async throws -> String {
        guard await ensurePermissions() else {
            throw NSError(domain: "OpenWatch", code: 5, userInfo: [NSLocalizedDescriptionKey: "Microphone and speech recognition permissions are required. Grant them once in OpenWatch on iPhone."])
        }
        let speechRecognizer = try speechRecognizer(localeIdentifier: localeIdentifier)

        AppLog.info("Transcribing watch audio file=\(url.lastPathComponent) recognizerLocale=\(speechRecognizer.locale.identifier)")
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            recognitionTask = speechRecognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if !didResume { didResume = true; continuation.resume(throwing: error) }
                    return
                }
                guard let result, result.isFinal else { return }
                let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                AppLog.info("Watch audio transcription completed length=\(text.count)")
                if !didResume { didResume = true; continuation.resume(returning: text) }
            }
        }
    }
}
