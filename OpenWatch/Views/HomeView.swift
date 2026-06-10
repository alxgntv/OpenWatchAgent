import SwiftUI
import UIKit

struct HomeView: View {
    @ObservedObject var model: AppModel
    @State private var showAddAgent = false
    @State private var showServerAgentGuide = false

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
                Picker(selection: Binding(
                    get: { model.voiceLanguage },
                    set: { model.setVoiceLanguage($0) }
                )) {
                    ForEach(AppModel.availableVoiceLanguages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                } label: {
                    Label("Language", systemImage: "globe")
                }

                Toggle(isOn: Binding(
                    get: { model.ttsEnabled },
                    set: { model.setTTSEnabled($0) }
                )) {
                    Label("Speak replies on Watch", systemImage: model.ttsEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                }

                Picker(selection: Binding(
                    get: { model.hapticType },
                    set: { model.setHapticType($0) }
                )) {
                    ForEach(WatchHapticType.allCases) { haptic in
                        Text(haptic.displayName).tag(haptic)
                    }
                } label: {
                    Label("Haptic Feedback", systemImage: "hand.tap.fill")
                }

                Picker(selection: Binding(
                    get: { model.ttsRate },
                    set: { model.setTTSRate($0) }
                )) {
                    ForEach(AppModel.availableTTSRates, id: \.self) { rate in
                        Text(Self.rateLabel(rate)).tag(rate)
                    }
                } label: {
                    Label("Speech Rate", systemImage: "speedometer")
                }
                .disabled(!model.ttsEnabled)
            } header: {
                Text("Settings")
            } footer: {
                Text("Language controls both speech recognition and spoken answers on Apple Watch.")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Greeting phrase")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Hello Sir", text: Binding(
                        get: { model.launchGreetingPhrase },
                        set: { model.setLaunchGreetingPhrase($0) }
                    ), axis: .vertical)
                    .textInputAutocapitalization(.sentences)
                }

                Picker(selection: Binding(
                    get: { model.launchGreetingLanguage },
                    set: { model.setLaunchGreetingLanguage($0) }
                )) {
                    ForEach(AppModel.availableLaunchGreetingLanguages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                } label: {
                    Label("Greeting language", systemImage: "globe")
                }

                Picker(selection: Binding(
                    get: { model.launchGreetingVoiceIdentifier },
                    set: { model.setLaunchGreetingVoiceIdentifier($0) }
                )) {
                    ForEach(model.launchGreetingVoiceOptions) { voice in
                        Text(voice.name).tag(voice.id)
                    }
                } label: {
                    Label("Greeting voice", systemImage: "person.wave.2")
                }
                .disabled(model.launchGreetingVoiceOptions.isEmpty)
            } header: {
                Text("Launch Greeting")
            } footer: {
                Text("Tap the phrase above to edit it. Your Apple Watch speaks it once when OpenWatch opens. Leave empty to stay silent.")
            }

            if model.agentsLoading && model.gatewayAgents.isEmpty {
                Section {
                    HStack { ProgressView(); Text("Loading agents…") }
                }
            }

            ForEach(model.sortedAgentsForDisplay) { agent in
                AgentSessionsSection(model: model, agent: agent)
            }

            Section {
                Button {
                    if model.canManageAgents {
                        AppLog.info("Add agent sheet opened (in-app create)")
                        showAddAgent = true
                    } else {
                        AppLog.info("Add agent server guide opened (no operator.admin)")
                        showServerAgentGuide = true
                    }
                } label: {
                    Label(
                        model.canManageAgents ? "Add agent" : "Add agent on server",
                        systemImage: "plus.circle.fill"
                    )
                }
                .disabled(model.isCreatingAgent)
            } footer: {
                if model.canManageAgents {
                    Text("Creates the agent on your gateway from this iPhone. Main Actor stays first.")
                } else {
                    Text("In-app create needs operator.admin on this phone. Tap above for server steps you can copy.")
                }
            }

            Section {
                Button("Disconnect gateway", role: .destructive) {
                    model.disconnect()
                }
            }
        }
        .navigationTitle("OpenWatch")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    AppLog.info("Home refresh sessions tapped")
                    Task { await model.refreshSessions() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.sessionsLoading)
            }
        }
        .refreshable { await model.refreshSessions() }
        .task { await model.refreshSessions(showErrors: false) }
        .onAppear { AppLog.info("HomeView appeared jobs=\(model.jobs.count)") }
        .sheet(isPresented: $showAddAgent) {
            AddAgentSheet(model: model, isPresented: $showAddAgent)
        }
        .sheet(isPresented: $showServerAgentGuide) {
            AddAgentServerGuideSheet(isPresented: $showServerAgentGuide)
        }
        .alert("Gateway", isPresented: Binding(
            get: { model.errorBanner != nil },
            set: { if !$0 { model.errorBanner = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorBanner = nil }
        } message: {
            Text(model.errorBanner ?? "")
        }
    }

    private static func rateLabel(_ rate: Double) -> String {
        rate == 1.0 ? "1x" : String(format: "%.2fx", rate)
    }
}

/// One agent block: standard section header + selectable row + that agent's sessions.
private struct AgentSessionsSection: View {
    @ObservedObject var model: AppModel
    let agent: GatewayAgentRow

    private var agentSessions: [GatewaySessionRow] {
        model.gatewaySessions(forAgentId: agent.id)
    }

    var body: some View {
        Section {
            AgentListRowView(
                agent: agent,
                isSelected: model.selectedAgentId == agent.id
            )
            .contentShape(Rectangle())
            .onTapGesture {
                AppLog.info("Agent row tapped id=\(agent.id) name=\(agent.displayName)")
                model.selectAgent(agent.id)
            }

            Button {
                AppLog.info("Tap to listen tapped agentId=\(agent.id)")
                model.startListen(forAgentId: agent.id)
            } label: {
                Label("Tap to listen", systemImage: "mic.fill")
            }

            if model.isVoiceJobActive(forAgentId: agent.id), let job = model.activeVoiceJob {
                HStack {
                    ProgressView()
                    Text(job.statusDetail ?? job.status.rawValue.capitalized)
                        .foregroundStyle(.secondary)
                }
            }

            if agentSessions.isEmpty {
                if model.sessionsLoading {
                    HStack { ProgressView(); Text("Loading sessions…") }
                } else {
                    Text("No sessions for this agent yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(agentSessions) { session in
                    NavigationLink {
                        SessionDetailView(model: model, session: session)
                    } label: {
                        SessionCardView(session: session)
                    }
                }
            }
        } header: {
            Text(agent.displayName)
                .foregroundStyle(.secondary)
        } footer: {
            if model.selectedAgentId == agent.id {
                Text("Active for voice and new sessions.")
            }
        }
    }
}

/// Standard list row for one gateway agent (system fonts, checkmark selection).
struct AgentListRowView: View {
    let agent: GatewayAgentRow
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            agentLeading
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName)
                    .foregroundStyle(.primary)
                if let subtitle = agentSubtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder private var agentLeading: some View {
        if let emoji = agent.emoji, !emoji.isEmpty {
            Text(emoji)
                .font(.title2)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
    }

    private var agentSubtitle: String? {
        if let model = agent.modelLabel, !model.isEmpty {
            return model.replacingOccurrences(of: "/", with: " · ")
        }
        if let subtitle = agent.subtitle, !subtitle.isEmpty {
            return subtitle
        }
        return agent.isDefault ? "Default agent" : nil
    }
}

/// Sheet to create a new gateway agent (`agents.create`).
struct AddAgentSheet: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var emoji = "🥗"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Emoji", text: $emoji)
                } header: {
                    Text("Agent")
                } footer: {
                    Text("Example: Nutritionist · 🥗. The gateway derives the agent id from the name (e.g. nutritionist).")
                }
            }
            .navigationTitle("Add Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        AppLog.info("Add agent sheet cancelled")
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        AppLog.info("Add agent create tapped name=\(name)")
                        Task {
                            await model.createAgent(name: name, emoji: emoji)
                            if model.errorBanner == nil {
                                isPresented = false
                            }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || model.isCreatingAgent)
                }
            }
            .overlay {
                if model.isCreatingAgent {
                    ProgressView("Creating…")
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

/// A tappable card representing one real gateway session.
struct SessionCardView: View {
    let session: GatewaySessionRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
                .foregroundStyle(.primary)
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
    @State private var browserURL: IdentifiableURL?
    @State private var draft: String = ""
    @State private var sending = false
    @State private var showWatchHint = false
    @FocusState private var inputFocused: Bool

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
            .environment(\.openURL, OpenURLAction { url in
                // Open agent-provided links inside the app. SFSafariViewController only supports http/https;
                // hand any other scheme back to the system instead of presenting an unsupported URL.
                if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                    AppLog.info("In-session link tapped, opening in-app browser url=\(url.absoluteString)")
                    browserURL = IdentifiableURL(url: url)
                    return .handled
                }
                AppLog.info("In-session link tapped with non-web scheme, deferring to system url=\(url.absoluteString)")
                return .systemAction
            })
            .sheet(item: $browserURL) { item in
                SafariView(url: item.url)
                    .ignoresSafeArea()
            }
            .onChange(of: messages.last?.id) { _, lastID in
                guard let lastID else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(lastID, anchor: .bottom) }
            }
            .alert("Open OpenWatch on your Watch", isPresented: $showWatchHint) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("watchOS does not let the iPhone launch the Watch app. Open OpenWatch on your Apple Watch, then tap the mic again to record.")
            }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    /// iMessage-style input bar pinned to the bottom: a real text field plus a trailing control that switches between
    /// a send button (when there is text) and a Watch mic button (when empty), and a spinner while a turn is in flight.
    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Message", text: $draft, axis: .vertical)
                .textInputAutocapitalization(.sentences)
                .lineLimit(1 ... 5)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .disabled(isBusy)
            trailingControl
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color(.systemGray3), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// The trailing control mirrors the Watch's Speak button states: spinner while busy, send arrow when there's text,
    /// otherwise the Watch mic (red + pulsing while the Watch is recording).
    @ViewBuilder private var trailingControl: some View {
        if isBusy {
            ProgressView()
                .frame(width: 26, height: 26)
        } else if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                AppLog.info("SessionDetailView mic tapped sessionKey=\(session.id) watchReachable=\(model.isWatchReachable)")
                // The iPhone cannot launch the Watch app (watchOS limitation). If the Watch app is not active, tell the
                // user to open it; otherwise remote-start the recording on the Watch.
                if model.isWatchReachable {
                    let agentId = model.agentId(fromSessionKey: session.id) ?? model.selectedAgentId
                    model.startListen(forAgentId: agentId)
                } else {
                    showWatchHint = true
                }
            } label: {
                Image(systemName: isListening ? "mic.fill" : "mic")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isListening ? Color.red : Color.accentColor)
                    .symbolEffect(.pulse, isActive: isListening)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
        }
    }

    /// The currently active job, if any (drives the input control state).
    private var activeJob: VoiceJob? {
        guard let id = model.activeJobId else { return nil }
        return model.jobs.first { $0.id == id }
    }

    /// True while a turn is being sent/processed (local send or a job running), so the field locks and shows a spinner.
    private var isBusy: Bool {
        if sending { return true }
        let status = activeJob?.status
        return status == .sending || status == .running
    }

    /// True while the Watch is actively recording the current job (drives the mic icon state/colour).
    private var isListening: Bool {
        activeJob?.status == .listening
    }

    /// Sends the typed text into this gateway session, then reloads the transcript so the new turn appears.
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        draft = ""
        inputFocused = false
        AppLog.info("SessionDetailView send tapped sessionKey=\(session.id) length=\(text.count)")
        Task {
            await model.sendText(text, to: session.id)
            messages = await model.history(for: session.id)
        }
    }

    private func load() async {
        loading = true
        // chat.history returns oldest-first; keep that order so the newest message is at the bottom (iMessage style).
        messages = await model.history(for: session.id)
        loading = false
        AppLog.info("SessionDetailView loaded sessionKey=\(session.id) messages=\(messages.count)")
    }
}

/// An iMessage-style chat bubble. User messages are blue and right-aligned; everything else is grey and left-aligned.
/// The body renders message segments so fenced code blocks get proper monospaced layout.
struct ChatBubble: View {
    let text: String
    let isUser: Bool
    var isError: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 56) }
            ChatMessageContent(text: text, isUser: isUser, isError: isError)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
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
}

/// One parsed piece of a message: either plain (inline-markdown) text or a fenced code block.
enum MessageSegment: Identifiable {
    case text(String)
    case code(language: String?, code: String)

    var id: String {
        switch self {
        case .text(let s): return "t:\(s.hashValue)"
        case .code(let lang, let code): return "c:\(lang ?? "")\(code.hashValue)"
        }
    }

    /// Splits a message into text/code segments based on triple-backtick fenced blocks.
    static func parse(_ input: String) -> [MessageSegment] {
        let pattern = "```([\\w+#.-]*)[\\t ]*\\r?\\n?([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [.text(input)]
        }
        let ns = input as NSString
        var segments: [MessageSegment] = []
        var lastEnd = 0
        for match in regex.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > lastEnd {
                let chunk = ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
                let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { segments.append(.text(trimmed)) }
            }
            let langRange = match.range(at: 1)
            let codeRange = match.range(at: 2)
            let lang = langRange.location != NSNotFound ? ns.substring(with: langRange) : ""
            let code = codeRange.location != NSNotFound ? ns.substring(with: codeRange) : ""
            segments.append(.code(
                language: lang.isEmpty ? nil : lang,
                code: code.trimmingCharacters(in: CharacterSet(charactersIn: "\n\r"))
            ))
            lastEnd = match.range.location + match.range.length
        }
        if lastEnd < ns.length {
            let chunk = ns.substring(with: NSRange(location: lastEnd, length: ns.length - lastEnd))
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { segments.append(.text(trimmed)) }
        }
        return segments.isEmpty ? [.text(input)] : segments
    }
}

/// Renders a message as a vertical stack of text and code-block segments inside a bubble.
struct ChatMessageContent: View {
    let text: String
    let isUser: Bool
    var isError: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MessageSegment.parse(text)) { segment in
                switch segment {
                case .text(let value):
                    Text(ChatMessageContent.attributed(value, isUser: isUser))
                        .font(.body)
                        .tint(isUser ? .white : .blue)
                        .foregroundStyle(textColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                }
            }
        }
    }

    private var textColor: Color {
        if isError { return .red }
        return isUser ? .white : .primary
    }

    /// Parses inline markdown (bold/italic/inline code/markdown links), then tags any remaining bare URLs as links.
    static func attributed(_ value: String, isUser: Bool) -> AttributedString {
        var attributed: AttributedString
        if let parsed = try? AttributedString(
            markdown: value,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            attributed = parsed
        } else {
            attributed = AttributedString(value)
        }

        // Make inline `code` runs visibly monospaced.
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(.body, design: .monospaced)
        }

        // Detect bare URLs (e.g. "myads.id/x") that markdown did not turn into links, and link them.
        let plain = String(attributed.characters)
        let nsLength = (plain as NSString).length
        if nsLength > 0, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            detector.enumerateMatches(in: plain, range: NSRange(location: 0, length: nsLength)) { result, _, _ in
                guard let result, let url = result.url, let r = Range(result.range, in: plain) else { return }
                let startOffset = plain.distance(from: plain.startIndex, to: r.lowerBound)
                let length = plain.distance(from: r.lowerBound, to: r.upperBound)
                let lower = attributed.characters.index(attributed.startIndex, offsetBy: startOffset)
                let upper = attributed.characters.index(lower, offsetBy: length)
                if attributed[lower..<upper].link == nil {
                    attributed[lower..<upper].link = url
                    attributed[lower..<upper].underlineStyle = .single
                    attributed[lower..<upper].foregroundColor = isUser ? .white : .blue
                }
            }
        }
        return attributed
    }
}

/// A monospaced code-block card with an optional language label and a copy button. Long lines scroll horizontally.
struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text((language?.isEmpty == false ? language! : "code").uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 8)
                Button {
                    UIPasteboard.general.string = code
                    AppLog.info("Code snippet copied to clipboard length=\(code.count)")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.13))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
