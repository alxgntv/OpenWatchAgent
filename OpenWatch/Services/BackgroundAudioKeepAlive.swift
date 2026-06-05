import AVFoundation
import Foundation

/// Keeps the iPhone app alive while it processes work triggered by the Watch (transcription + the long gateway
/// WebSocket round-trip) even when the app itself is backgrounded.
///
/// Why this exists: a Watch `transferFile` wakes the backgrounded iPhone app, but `beginBackgroundTask` only grants
/// ~30s of runtime — far less than a long agent reply can take, so the WebSocket gets suspended and the turn never
/// completes until the user manually foregrounds the app. The app already declares the `audio` UIBackgroundMode, but
/// that mode only actually holds the app alive while an audio session is active. This service activates a silent,
/// non-mixing playback audio session for the duration of the work so the `audio` background mode keeps the process
/// running, then deactivates it when the work is done.
///
/// It is reference-counted so overlapping Watch turns (multiple jobs in flight) only deactivate once everyone is done.
@MainActor
enum BackgroundAudioKeepAlive {
    /// How many in-flight Watch jobs currently need the app kept alive. Deactivation only happens at zero.
    private static var activeCount = 0

    /// Silent player that produces no audible sound but keeps the audio route (and therefore the background mode) live.
    private static var silentPlayer: AVAudioPlayer?

    /// Begins (or re-enters) the keep-alive window. Safe to call for every Watch job; reference-counted.
    static func begin(reason: String) {
        activeCount += 1
        AppLog.info("BackgroundAudioKeepAlive begin reason=\(reason) activeCount=\(activeCount)")
        guard activeCount == 1 else {
            AppLog.info("BackgroundAudioKeepAlive already active; reusing existing session reason=\(reason)")
            return
        }
        activateAudioSession()
        startSilentPlayback()
    }

    /// Ends one keep-alive request. The audio session is only torn down when the last request ends.
    static func end(reason: String) {
        guard activeCount > 0 else {
            AppLog.info("BackgroundAudioKeepAlive end called with no active session reason=\(reason)")
            return
        }
        activeCount -= 1
        AppLog.info("BackgroundAudioKeepAlive end reason=\(reason) activeCount=\(activeCount)")
        guard activeCount == 0 else {
            AppLog.info("BackgroundAudioKeepAlive still has active jobs; keeping session reason=\(reason)")
            return
        }
        stopSilentPlayback()
        deactivateAudioSession()
    }

    /// Configures a playback audio session that is allowed to run in the background via the `audio` UIBackgroundMode.
    private static func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // `.playback` + active session is what lets the declared `audio` background mode hold the app alive.
            // `.mixWithOthers` so we never interrupt the user's music/podcasts while we are merely keeping alive.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
            AppLog.info("BackgroundAudioKeepAlive audio session activated category=playback mixWithOthers=true")
        } catch {
            AppLog.error("BackgroundAudioKeepAlive failed to activate audio session: \(error.localizedDescription)")
        }
    }

    private static func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            AppLog.info("BackgroundAudioKeepAlive audio session deactivated")
        } catch {
            AppLog.error("BackgroundAudioKeepAlive failed to deactivate audio session: \(error.localizedDescription)")
        }
    }

    /// Loops a tiny silent buffer so there is a live audio output keeping the `audio` background mode engaged.
    private static func startSilentPlayback() {
        do {
            let data = try makeSilentWavData()
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = -1
            player.volume = 0
            player.prepareToPlay()
            player.play()
            silentPlayer = player
            AppLog.info("BackgroundAudioKeepAlive silent playback started (looping, volume=0)")
        } catch {
            AppLog.error("BackgroundAudioKeepAlive failed to start silent playback: \(error.localizedDescription)")
        }
    }

    private static func stopSilentPlayback() {
        silentPlayer?.stop()
        silentPlayer = nil
        AppLog.info("BackgroundAudioKeepAlive silent playback stopped")
    }

    /// Builds an in-memory mono 8 kHz, 16-bit PCM WAV of ~0.2s of silence. Generated in code so we ship no audio asset.
    private static func makeSilentWavData() throws -> Data {
        let sampleRate = 8000
        let channels = 1
        let bitsPerSample = 16
        let durationSeconds = 0.2
        let frameCount = Int(Double(sampleRate) * durationSeconds)
        let bytesPerFrame = channels * (bitsPerSample / 8)
        let dataSize = frameCount * bytesPerFrame
        let byteRate = sampleRate * bytesPerFrame

        var data = Data()
        func appendString(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func appendUInt32LE(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func appendUInt16LE(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        appendString("RIFF")
        appendUInt32LE(UInt32(36 + dataSize))
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32LE(16)
        appendUInt16LE(1)                          // PCM
        appendUInt16LE(UInt16(channels))
        appendUInt32LE(UInt32(sampleRate))
        appendUInt32LE(UInt32(byteRate))
        appendUInt16LE(UInt16(bytesPerFrame))
        appendUInt16LE(UInt16(bitsPerSample))
        appendString("data")
        appendUInt32LE(UInt32(dataSize))
        data.append(Data(count: dataSize))         // all-zero samples == silence

        return data
    }
}
