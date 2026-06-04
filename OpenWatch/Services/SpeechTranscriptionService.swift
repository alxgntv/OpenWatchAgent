import AVFoundation
import Combine
import Speech

@MainActor
final class SpeechTranscriptionService: NSObject, ObservableObject {
    @Published private(set) var isListening = false

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))

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
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

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

    func stopAndTranscribe() async throws -> String {
        guard isListening else {
            throw NSError(domain: "OpenWatch", code: 2, userInfo: [NSLocalizedDescriptionKey: "Not currently listening."])
        }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        isListening = false

        return try await withCheckedThrowingContinuation { continuation in
            guard let speechRecognizer, let recognitionRequest else {
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
    func transcribeFile(at url: URL) async throws -> String {
        guard await ensurePermissions() else {
            throw NSError(domain: "OpenWatch", code: 5, userInfo: [NSLocalizedDescriptionKey: "Microphone and speech recognition permissions are required. Grant them once in OpenWatch on iPhone."])
        }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw NSError(domain: "OpenWatch", code: 6, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer is unavailable."])
        }

        AppLog.info("Transcribing watch audio file=\(url.lastPathComponent)")
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
