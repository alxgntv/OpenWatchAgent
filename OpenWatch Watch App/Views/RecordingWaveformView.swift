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

// ─── Ariadne's Thread [AT-0145] ─────────────────────
// What: Static centered glowing gradient lobes that pulse with mic level (no horizontal scroll).
// Why:  Scrolling waveform felt wrong; user wants a fixed center visual like the reference image.
// Date: 2026-06-10
// Related: [AT-0144] RecordingWaveformView
// ─────────────────────────────────────────────────────
// ─── Ariadne's Thread [AT-0146] ─────────────────────
// What: Stretch the static waveform to the same full width as Speak/Cancel buttons.
// Why:  Narrow centered lobes no longer matched the button row width the user expects.
// Date: 2026-06-10
// Related: [AT-0145] RecordingWaveformView
// ─────────────────────────────────────────────────────
struct RecordingWaveformView: View {
    let level: Double
    let isActive: Bool

    private let barCount = 11
    private let barOverlap: CGFloat = 8
    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private let barWeights: [CGFloat] = [0.42, 0.56, 0.7, 0.84, 0.95, 1.0, 0.95, 0.84, 0.7, 0.56, 0.42]

    @State private var barHeights: [CGFloat] = []

    private var gradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 1.0, green: 0.45, blue: 0.18),
                Color(red: 0.98, green: 0.22, blue: 0.55),
                Color(red: 0.62, green: 0.18, blue: 0.95),
                Color(red: 0.22, green: 0.48, blue: 1.0),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let barWidth = (geometry.size.width + CGFloat(barCount - 1) * barOverlap) / CGFloat(barCount)
            HStack(alignment: .center, spacing: -barOverlap) {
                ForEach(0..<barCount, id: \.self) { index in
                    let height = barHeights.indices.contains(index) ? barHeights[index] : 0.12
                    Capsule(style: .continuous)
                        .fill(gradient)
                        .frame(
                            width: barWidth,
                            height: max(4, height * WatchRecordingLayout.secondaryButtonHeight)
                        )
                        .opacity(0.92)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .compositingGroup()
            .blur(radius: 1.6)
        }
        .padding(.horizontal, WatchRecordingLayout.buttonHorizontalInset)
        .frame(maxWidth: .infinity)
        .frame(height: WatchRecordingLayout.secondaryButtonHeight)
        .clipped()
        .onAppear {
            resetBars()
        }
        .onChange(of: isActive) { _, active in
            if !active {
                resetBars()
            }
        }
        .onReceive(tick) { _ in
            guard isActive else { return }
            updateBars(level: CGFloat(level))
        }
    }

    private func resetBars() {
        barHeights = Array(repeating: 0.12, count: barCount)
    }

    private func updateBars(level: CGFloat) {
        guard barHeights.count == barCount else {
            resetBars()
            return
        }
        let clamped = min(1, max(0, level))
        let voice = 0.12 + clamped * 0.88
        for index in barHeights.indices {
            let target = voice * barWeights[index]
            if target >= barHeights[index] {
                barHeights[index] = barHeights[index] * 0.2 + target * 0.8
            } else {
                barHeights[index] = barHeights[index] * 0.78 + target * 0.22
            }
        }
    }
}
