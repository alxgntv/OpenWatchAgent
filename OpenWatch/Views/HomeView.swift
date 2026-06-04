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

            Section {
                Button {
                    model.toggleListenOnPhone()
                } label: {
                    Label("Tap to listen", systemImage: "mic.fill")
                }

                if let job = activeJob, job.status == .listening || job.status == .sending || job.status == .running {
                    HStack {
                        ProgressView()
                        Text(job.statusDetail ?? job.status.rawValue.capitalized)
                    }
                }
            } header: {
                Text("Listen")
            } footer: {
                Text("Starts a new recording on the Watch. The Watch app must be open on screen — watchOS does not allow the iPhone to launch the Watch app or its microphone in the background.")
            }

            Section("Voice") {
                Toggle(isOn: Binding(
                    get: { model.ttsEnabled },
                    set: { model.setTTSEnabled($0) }
                )) {
                    Label("Speak replies on Watch", systemImage: model.ttsEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                }

                Picker(selection: Binding(
                    get: { model.ttsLanguage },
                    set: { model.setTTSLanguage($0) }
                )) {
                    ForEach(AppModel.availableVoiceLanguages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                } label: {
                    Label("Language", systemImage: "globe")
                }
                .disabled(!model.ttsEnabled)
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
                    Spacer()
                    if model.sessionsLoading {
                        ProgressView()
                    } else {
                        Button {
                            Task { await model.refreshSessions() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
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
/// Rendered as an iMessage-style thread: oldest messages on top, newest at the bottom, scrolled to the latest.
struct SessionDetailView: View {
    @ObservedObject var model: AppModel
    let session: GatewaySessionRow

    @State private var messages: [ChatHistoryMessage] = []
    @State private var loading = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if loading {
                        HStack(spacing: 8) { ProgressView(); Text("Loading transcript…") }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 32)
                    } else if messages.isEmpty {
                        Text("No messages in this session.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 32)
                    } else {
                        ForEach(messages) { message in
                            ChatBubble(text: message.text, isUser: message.isUser)
                                .id(message.id)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(session.title)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { inputBar }
            .refreshable { await load(proxy: proxy) }
            .task { await load(proxy: proxy) }
        }
    }

    /// iMessage-style input bar pinned to the bottom. iPhone never records audio itself, so the mic button
    /// (right side, no "+") remotely starts listening on the Watch via the existing toggleListenOnPhone() path.
    private var inputBar: some View {
        HStack(spacing: 10) {
            Text(isListening ? "Listening on Watch…" : "Tap the mic to talk on your Watch")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                AppLog.info("SessionDetailView mic tapped sessionKey=\(session.id); triggering remote listen on Watch")
                model.toggleListenOnPhone()
            } label: {
                Image(systemName: isListening ? "mic.fill" : "mic")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isListening ? Color.red : Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color(.systemGray3), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// True while the Watch is actively recording the current job (drives the mic icon state/colour).
    private var isListening: Bool {
        guard let id = model.activeJobId else { return false }
        return model.jobs.first { $0.id == id }?.status == .listening
    }

    private func load(proxy: ScrollViewProxy?) async {
        loading = true
        // chat.history returns oldest-first; keep that order so the newest message is at the bottom (iMessage style).
        messages = await model.history(for: session.id)
        loading = false
        AppLog.info("SessionDetailView loaded sessionKey=\(session.id) messages=\(messages.count)")
        // Jump to the latest message, like opening an iMessage thread.
        if let proxy, let last = messages.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

/// An iMessage-style chat bubble. User messages are blue and right-aligned; everything else is grey and left-aligned.
struct ChatBubble: View {
    let text: String
    let isUser: Bool
    var isError: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 56) }
            Text(text)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .foregroundStyle(textColor)
                .background(bubbleColor)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            if !isUser { Spacer(minLength: 56) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(.vertical, 2)
    }

    private var bubbleColor: Color {
        if isError { return Color.red.opacity(0.15) }
        return isUser ? Color.blue : Color(.systemGray5)
    }

    private var textColor: Color {
        if isError { return .red }
        return isUser ? .white : .primary
    }
}
