import SwiftUI

/// One vertical page == one chat session. Swiping (up/down + Digital Crown) to the trailing empty page starts a new session.
struct WatchSessionPage: View {
    @ObservedObject var model: WatchAppModel
    let session: WatchSession
    let index: Int

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                speakButton
                muteButton
                // Only surface non-process hints (permission/pairing errors) here; live process status lives in the button.
                if index == model.currentIndex, session.activeJob == nil, !isRecordingHere, let hint = model.statusHint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                history
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(session.jobs.isEmpty ? "New" : "Session \(index)")
    }

    /// Recording is global (one recorder) and always belongs to the visible session, so it only shows on the current page.
    private var isRecordingHere: Bool {
        model.isRecording && index == model.currentIndex
    }

    @ViewBuilder
    private var history: some View {
        if session.jobs.isEmpty {
            Text("Tap Speak to talk to your agent.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                // jobs[0] is the newest turn. Inside each turn the agent reply is shown above the recognized text, so the
                // newest message (the latest reply) is the very top line — matching the iPhone's newest-first order.
                ForEach(session.jobs) { job in
                    VStack(alignment: .leading, spacing: 2) {
                        if let result = job.resultText {
                            Text(result)
                                .font(.footnote)
                        } else if let error = job.errorMessage {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                        if let transcript = job.transcript {
                            Text(transcript)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var speakButton: some View {
        Button {
            model.toggleRecord()
        } label: {
            VStack(spacing: 4) {
                if isRecordingHere {
                    Image(systemName: "stop.fill").font(.title2)
                    Text("Stop & Send").font(.caption2)
                } else if let job = session.activeJob {
                    // Already sent to work in this session: spinner replaces the mic and the live status is the label.
                    ProgressView()
                    Text(job.statusDetail ?? "Working…")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                } else {
                    Image(systemName: "mic.fill").font(.title2)
                    Text("Speak").font(.caption2)
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(isRecordingHere ? .red : .blue)
        .disabled(session.activeJob != nil)
    }

    /// Per-session voice mute. Disabled (and shown off) when the iPhone has turned voice off globally.
    private var muteButton: some View {
        Button {
            model.toggleMute(sessionId: session.id)
        } label: {
            Label(
                session.muted ? "Voice Off" : "Voice On",
                systemImage: session.muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
            )
            .font(.caption2)
        }
        .buttonStyle(.bordered)
        .tint(session.muted ? .gray : .blue)
        .disabled(!model.globalTtsEnabled)
    }
}

struct WatchNotPairedView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "iphone")
            Text("Pair on iPhone")
                .font(.caption2)
                .multilineTextAlignment(.center)
        }
    }
}
