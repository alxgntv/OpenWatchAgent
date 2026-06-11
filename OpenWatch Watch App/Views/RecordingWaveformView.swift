import Combine
import SwiftUI

// ─── Ariadne's Thread [AT-0143] ─────────────────────
// What: Live voice waveform shown under Cancel while recording.
// Why:  Users need a mic-driven visual outside the Send button that reflects real input levels.
// Date: 2026-06-10
// Related: [AT-0023] WatchAudioRecorder.updateMeterLevel, [AT-0141] WatchHomeView.muteButton
// ─────────────────────────────────────────────────────
enum WatchRecordingLayout {
    /// Matches watchOS `.bordered` + `.caption2` secondary buttons such as Cancel.
    static let secondaryButtonHeight: CGFloat = 32
    /// watchOS `.bordered` / `.borderedProminent` chrome is narrower than `maxWidth: .infinity`.
    static let buttonHorizontalInset: CGFloat = 10
}

// ─── Ariadne's Thread [AT-0157] ─────────────────────
// What: Observe recorder directly; per-bar phase wobble; centered compact waveform + timer row.
// Why:  Stale `level` prop froze bars after parent stopped refreshing; layout spread bars and timer apart.
// Date: 2026-06-11
// Related: [AT-0156] RecordingWaveformView, [AT-0023] WatchAudioRecorder.meterLevel
// ─────────────────────────────────────────────────────
struct RecordingWaveformView: View {
    @ObservedObject var recorder: WatchAudioRecorder
    let isActive: Bool

    private let barCount = 7
    private let barWidth: CGFloat = 5
    private let barSpacing: CGFloat = 4
    private let cornerRadius: CGFloat = 2.5
    private let minBarHeight: CGFloat = 8
    private let maxBarExtra: CGFloat = 18
    private let tick = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    @State private var barLevels: [CGFloat] = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            let elapsed = recorder.recordingStartedAt.map { timeline.date.timeIntervalSince($0) } ?? 0

            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .center, spacing: barSpacing) {
                    ForEach(0..<barCount, id: \.self) { index in
                        let barLevel = barLevels.indices.contains(index) ? barLevels[index] : 0
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(.white)
                            .frame(width: barWidth, height: minBarHeight + barLevel * maxBarExtra)
                            .animation(.easeOut(duration: 0.1), value: barLevel)
                    }
                }

                Text(formatDuration(elapsed))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, WatchRecordingLayout.buttonHorizontalInset)
        .frame(maxWidth: .infinity)
        .frame(height: WatchRecordingLayout.secondaryButtonHeight)
        .clipped()
        .onAppear {
            resetBars()
            updateBars(level: CGFloat(recorder.meterLevel), time: Date().timeIntervalSinceReferenceDate)
        }
        .onChange(of: isActive) { _, active in
            if active {
                resetBars()
                updateBars(level: CGFloat(recorder.meterLevel), time: Date().timeIntervalSinceReferenceDate)
            } else {
                resetBars()
            }
        }
        .onReceive(recorder.$meterLevel) { newLevel in
            guard isActive else { return }
            updateBars(level: CGFloat(newLevel), time: Date().timeIntervalSinceReferenceDate)
        }
        .onReceive(tick) { _ in
            guard isActive else { return }
            updateBars(level: CGFloat(recorder.meterLevel), time: Date().timeIntervalSinceReferenceDate)
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func resetBars() {
        barLevels = Array(repeating: 0.08, count: barCount)
    }

    private func updateBars(level: CGFloat, time: TimeInterval) {
        guard barLevels.count == barCount else {
            resetBars()
            return
        }
        let clamped = min(1, max(0, level))
        let voice = 0.08 + clamped * 0.92
        for index in barLevels.indices {
            let phase = time * 5.0 + Double(index) * 1.15
            let wobble = 0.68 + 0.32 * CGFloat((sin(phase) + 1) / 2)
            let target = voice * wobble
            if target >= barLevels[index] {
                barLevels[index] = barLevels[index] * 0.4 + target * 0.6
            } else {
                barLevels[index] = barLevels[index] * 0.78 + target * 0.22
            }
        }
    }
}
