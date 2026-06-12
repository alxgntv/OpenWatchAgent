import AVFoundation
import Combine
import SwiftUI

// ─── Ariadne's Thread [AT-0170] ─────────────────────
// What: Compact watchOS audio player for locally stored voice messages (AVAudioPlayer).
// Why:  Users must replay their own recordings in chat; full iOS sliders are too large for Watch.
// Date: 2026-06-12
// Related: [AT-0168] VoiceJob.localAudioFileName, [AT-0169] WatchVoiceMessageStore
// ─────────────────────────────────────────────────────
struct WatchVoiceMessagePlayerView: View {
    let fileURL: URL

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var totalTime: TimeInterval = 0
    @State private var loadFailed = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(loadFailed)

            VStack(alignment: .leading, spacing: 3) {
                Text("Voice message")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ProgressView(value: progressFraction)
                    .tint(.blue)
                HStack {
                    Text(formatTime(currentTime))
                    Spacer()
                    Text(formatTime(totalTime))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            stopAndCleanup()
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            updateProgress()
        }
    }

    private var progressFraction: Double {
        guard totalTime > 0 else { return 0 }
        return min(1, max(0, currentTime / totalTime))
    }

    private func togglePlayback() {
        guard let player else {
            AppLog.error("Watch voice playback toggle failed: player missing url=\(fileURL.path)")
            return
        }
        if isPlaying {
            player.pause()
            isPlaying = false
            AppLog.info("Watch voice playback paused url=\(fileURL.lastPathComponent) currentTime=\(currentTime)")
        } else {
            SpeechPlaybackService.shared.stop()
            do {
                try activatePlaybackSession()
                player.play()
                isPlaying = true
                AppLog.info("Watch voice playback started url=\(fileURL.lastPathComponent) duration=\(totalTime)")
            } catch {
                AppLog.error("Watch voice playback start failed url=\(fileURL.lastPathComponent) error=\(error.localizedDescription)")
            }
        }
    }

    private func setupPlayer() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            loadFailed = true
            AppLog.error("Watch voice playback file missing url=\(fileURL.path)")
            return
        }
        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: fileURL)
            audioPlayer.prepareToPlay()
            player = audioPlayer
            totalTime = audioPlayer.duration
            currentTime = 0
            loadFailed = false
            AppLog.info("Watch voice playback ready url=\(fileURL.lastPathComponent) duration=\(totalTime)")
        } catch {
            loadFailed = true
            AppLog.error("Watch voice playback load failed url=\(fileURL.path) error=\(error.localizedDescription)")
        }
    }

    private func updateProgress() {
        guard let player, player.isPlaying else { return }
        currentTime = player.currentTime
        if currentTime >= totalTime, totalTime > 0 {
            isPlaying = false
            currentTime = totalTime
            AppLog.info("Watch voice playback finished url=\(fileURL.lastPathComponent)")
        }
    }

    private func stopAndCleanup() {
        player?.stop()
        player = nil
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        AppLog.info("Watch voice playback cleaned up url=\(fileURL.lastPathComponent)")
    }

    private func activatePlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true, options: [])
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let seconds = Int(time) % 60
        let minutes = Int(time) / 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
