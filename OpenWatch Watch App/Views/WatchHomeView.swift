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
                if index == model.currentIndex, let hint = model.statusHint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if session.activeJob != nil {
                    ProgressView()
                }
                history
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(session.jobs.isEmpty ? "New" : "Session \(index)")
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
                ForEach(session.jobs.reversed()) { job in
                    VStack(alignment: .leading, spacing: 2) {
                        if let transcript = job.transcript {
                            Text(transcript)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let result = job.resultText {
                            Text(result)
                                .font(.footnote)
                        } else if let error = job.errorMessage {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
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
            VStack {
                Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                    .font(.title2)
                Text(model.isRecording ? "Stop & Send" : "Speak")
                    .font(.caption2)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isRecording ? .red : .blue)
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
