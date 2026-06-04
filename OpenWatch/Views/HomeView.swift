import SwiftUI
import UIKit

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
    @State private var browserURL: IdentifiableURL?

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
