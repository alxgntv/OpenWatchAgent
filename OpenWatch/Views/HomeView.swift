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

            Section("Voice") {
                Toggle(isOn: Binding(
                    get: { model.ttsEnabled },
                    set: { model.setTTSEnabled($0) }
                )) {
                    Label("Speak replies on Watch", systemImage: model.ttsEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                }
            }

            Section("Session") {
                Button {
                    model.startNewSession()
                } label: {
                    Label("New session", systemImage: "plus.bubble")
                }
            }

            Section {
                if model.gatewaySessions.isEmpty {
                    if model.sessionsLoading {
                        HStack { ProgressView(); Text("Loading sessions…") }
                    } else {
                        Text("No sessions yet. Pull down to refresh.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // Real gateway sessions; tap to open the full transcript loaded from the bot.
                    ForEach(model.gatewaySessions) { session in
                        NavigationLink {
                            SessionDetailView(model: model, session: session)
                        } label: {
                            SessionCardView(session: session)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Sessions")
                    if model.sessionsLoading { Spacer(); ProgressView() }
                }
            }

            Section {
                Button("Disconnect gateway", role: .destructive) {
                    model.disconnect()
                }
            }
        }
        .navigationTitle("OpenWatch")
        .refreshable { await model.refreshSessions() }
        .task { await model.refreshSessions() }
        .onAppear { AppLog.info("HomeView appeared jobs=\(model.jobs.count)") }
    }

    private var activeJob: VoiceJob? {
        guard let id = model.activeJobId else { return nil }
        return model.jobs.first { $0.id == id }
    }
}

/// A tappable card representing one real gateway session.
struct SessionCardView: View {
    let session: GatewaySessionRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
                .lineLimit(1)
            if let preview = session.preview, !preview.isEmpty {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                if let count = session.messageCount {
                    Text("\(count) message\(count == 1 ? "" : "s")")
                    if session.updatedAt != nil { Text("·") }
                }
                if let updated = session.updatedAt {
                    Text(updated, style: .relative)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

/// The full transcript for one session, loaded from the gateway via chat.history.
struct SessionDetailView: View {
    @ObservedObject var model: AppModel
    let session: GatewaySessionRow

    @State private var messages: [ChatHistoryMessage] = []
    @State private var loading = true

    var body: some View {
        List {
            if loading {
                HStack { ProgressView(); Text("Loading transcript…") }
            } else if messages.isEmpty {
                Text("No messages in this session.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(messages) { message in
                    ChatBubble(text: message.text, isUser: message.isUser)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        loading = true
        messages = await model.history(for: session.id)
        loading = false
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
