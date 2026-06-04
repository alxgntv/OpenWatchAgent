import AVFoundation

@MainActor
final class SpeechPlaybackService: NSObject {
    static let shared = SpeechPlaybackService()
    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks the reply to completion in the requested language. Utterances are queued (not interrupted), so playback
    /// always finishes the full text. Falls back to the system default voice if the language is unavailable on the Watch.
    func speak(_ text: String, language: String) {
        guard !text.isEmpty else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            AppLog.error("Watch TTS audio session setup failed: \(error.localizedDescription)")
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language) ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        AppLog.info("Watch TTS speaking length=\(text.count) language=\(language)")
        synthesizer.speak(utterance)
    }

    /// Immediately stops any current/queued speech and releases the audio session.
    func stop() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        AppLog.info("Watch TTS stopped")
    }
}

extension SpeechPlaybackService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            AppLog.info("Watch TTS finished")
            // Release the audio session only when nothing else is queued, so multi-part replies are not cut off.
            if !synthesizer.isSpeaking {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }
}
