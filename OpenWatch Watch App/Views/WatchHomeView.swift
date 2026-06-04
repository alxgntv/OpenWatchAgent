import SwiftUI

struct WatchHomeView: View {
    @ObservedObject var model: WatchAppModel

    var body: some View {
        VStack(spacing: 8) {
            if !model.isPaired {
                Image(systemName: "iphone")
                Text("Pair on iPhone")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
            } else {
                speakButton
                if let hint = model.statusHint ?? model.activeJob?.statusDetail {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if model.activeJob != nil {
                    ProgressView()
                }
                latestExchange
                Button {
                    model.startNewSession()
                } label: {
                    Label("New session", systemImage: "plus.bubble")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
            }
        }
        .navigationTitle("OpenWatch")
        .onAppear { AppLog.info("WatchHomeView appeared paired=\(model.isPaired)") }
    }

    @ViewBuilder
    private var latestExchange: some View {
        if let job = model.latestJob {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
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
