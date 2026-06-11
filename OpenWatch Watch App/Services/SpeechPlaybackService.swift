import AVFoundation

@MainActor
final class SpeechPlaybackService: NSObject {
    static let shared = SpeechPlaybackService()
    private let synthesizer = AVSpeechSynthesizer()
    var onPlaybackIdle: (() -> Void)?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks the reply to completion in the requested language. Utterances are queued (not interrupted), so playback
    /// always finishes the full text. Falls back to the system default voice if the language is unavailable on the Watch.
    func speak(_ text: String, language: String, rateMultiplier: Double, voiceIdentifier: String? = nil) {
        guard !text.isEmpty else { return }
        do {
            try activatePlaybackSession(context: "Watch TTS speak")
        } catch {
            AppLog.error("Watch TTS audio session setup failed: \(error.localizedDescription) code=\((error as NSError).code)")
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        let voice = resolveVoice(for: language, preferredIdentifier: voiceIdentifier)
        utterance.voice = voice
        let resolvedRate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(rateMultiplier)))
        utterance.rate = resolvedRate
        AppLog.info("Watch TTS speaking length=\(text.count) language=\(language) voice=\(voice.language) voiceId=\(voice.identifier) rateMultiplier=\(rateMultiplier) resolvedRate=\(resolvedRate)")
        synthesizer.speak(utterance)
    }

    // ─── Ariadne's Thread [AT-0136] ─────────────────────
    // What: watchOS-safe AVAudioSession activation for TTS (no pre-deactivate, no unsupported category options).
    // Why:  Launch greeting failed with OSStatus -50 because setActive(false) + spokenAudio/allowBluetoothA2DP at cold start.
    // Date: 2026-06-10
    // Related: [AT-0134] WatchAppModel.speakLaunchGreetingIfNeeded
    // ─────────────────────────────────────────────────────
    private func activatePlaybackSession(context: String) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true, options: [])
        logCurrentAudioRoute(session: session, context: context)
    }

    private func resolveVoice(for language: String, preferredIdentifier: String? = nil) -> AVSpeechSynthesisVoice {
        if let preferredIdentifier, !preferredIdentifier.isEmpty,
           let preferred = AVSpeechSynthesisVoice(identifier: preferredIdentifier) {
            AppLog.info("Watch TTS voice selected preferred voiceId=\(preferred.identifier) language=\(preferred.language)")
            return preferred
        }
        if let exact = AVSpeechSynthesisVoice(language: language) {
            return exact
        }
        let prefix = language.split(separator: "-", maxSplits: 1).first.map(String.init) ?? language
        if let partial = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language.hasPrefix(prefix) }) {
            AppLog.info("Watch TTS voice fallback requested=\(language) matched=\(partial.language) voiceId=\(partial.identifier)")
            return partial
        }
        let available = AVSpeechSynthesisVoice.speechVoices().map(\.language).joined(separator: ",")
        AppLog.error("Watch TTS voice missing for language=\(language); using en-US available=[\(available)]")
        return AVSpeechSynthesisVoice(language: "en-US") ?? AVSpeechSynthesisVoice.speechVoices().first!
    }

    /// Logs the resolved output ports so we can confirm whether the reply plays through headphones or the Watch speaker.
    private func logCurrentAudioRoute(session: AVAudioSession, context: String) {
        let route = session.currentRoute
        let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let usingHeadphoneOutput = route.outputs.contains {
            $0.portType == .bluetoothA2DP || $0.portType == .bluetoothHFP || $0.portType == .headphones
        }
        AppLog.info("[\(context)] audio output route outputs=[\(outputs)] usingHeadphoneOutput=\(usingHeadphoneOutput)")
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
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            AppLog.info("Watch TTS started utteranceLength=\(utterance.speechString.count)")
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            AppLog.info("Watch TTS finished")
            // Release the audio session only when nothing else is queued, so multi-part replies are not cut off.
            if !synthesizer.isSpeaking {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                onPlaybackIdle?()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance, error: Error?) {
        Task { @MainActor in
            AppLog.error("Watch TTS cancelled error=\(error?.localizedDescription ?? "nil")")
            self.onPlaybackIdle?()
        }
    }
}
