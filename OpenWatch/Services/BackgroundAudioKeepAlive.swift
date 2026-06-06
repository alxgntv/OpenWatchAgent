import AVFoundation
import Foundation

/// Keeps the iPhone app alive while it relays Watch audio chunks through the long gateway WebSocket round-trip.
///
/// Why this exists: `beginBackgroundTask` only grants a short runtime window, but an OpenClaw Talk + chat turn can run
/// longer. The app already declares the `audio` UIBackgroundMode, but that mode only holds the app alive while an audio
/// session is active. This service activates silent playback for the duration of relay work, then deactivates it.
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
