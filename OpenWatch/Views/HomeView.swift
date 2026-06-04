import SwiftUI

struct HomeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text("Connected")
                            .font(.headline)
                        if let url = model.pairing.gatewayURL {
                            Text(url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }

            Section("Voice on iPhone") {
                Button {
                    model.toggleListenOnPhone()
                } label: {
                    Label(
                        activeJob?.status == .listening ? "Tap to send" : "Tap to listen",
                        systemImage: activeJob?.status == .listening ? "paperplane.fill" : "mic.fill"
                    )
                }

                if let job = activeJob, job.status == .listening || job.status == .sending || job.status == .running {
                    HStack {
                        ProgressView()
                        Text(job.statusDetail ?? job.status.rawValue.capitalized)
                    }
                }
            }

            Section("Session") {
                Button {
                    model.startNewSession()
                } label: {
                    Label("New session", systemImage: "plus.bubble")
                }
            }

            Section("Conversation") {
                if model.jobs.isEmpty {
                    Text("Use your Apple Watch or tap Listen above.")
                        .foregroundStyle(.secondary)
                } else {
                    // One session = one chat thread. Oldest turn on top, newest at the bottom, just like the Watch.
                    ForEach(orderedJobs) { job in
                        ChatTurnView(job: job)
                    }
                }
            }

            Section {
                Button("Disconnect gateway", role: .destructive) {
                    model.disconnect()
                }
            }
        }
        .navigationTitle("OpenWatch")
        .onAppear { AppLog.info("HomeView appeared jobs=\(model.jobs.count)") }
    }

    private var activeJob: VoiceJob? {
        guard let id = model.activeJobId else { return nil }
        return model.jobs.first { $0.id == id }
    }

    /// Oldest turn first so the conversation reads top-to-bottom. A concrete Array keeps SwiftUI's list diffing stable.
    private var orderedJobs: [VoiceJob] {
        model.jobs.sorted { $0.createdAt < $1.createdAt }
    }
}

/// A single request/response turn inside the current session, rendered as chat bubbles.
struct ChatTurnView: View {
    let job: VoiceJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let transcript = job.transcript, !transcript.isEmpty {
                ChatBubble(text: transcript, isUser: true)
            }

            if let result = job.resultText, !result.isEmpty {
                ChatBubble(text: result, isUser: false)
            } else if job.status == .failed {
                ChatBubble(text: job.errorMessage ?? "Failed", isUser: false, isError: true)
            } else if job.status == .running || job.status == .sending || job.status == .listening {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(job.statusDetail ?? job.status.rawValue.capitalized)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChatBubble: View {
    let text: String
    let isUser: Bool
    var isError: Bool = false

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 32) }
            Text(text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleColor)
                .foregroundStyle(isError ? Color.red : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !isUser { Spacer(minLength: 32) }
        }
    }

    private var bubbleColor: Color {
        if isError { return Color.red.opacity(0.12) }
        return isUser ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.14)
    }
}
