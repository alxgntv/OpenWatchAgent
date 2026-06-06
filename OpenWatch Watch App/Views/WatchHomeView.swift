import SwiftUI

/// Shared compact "session + date" stamp for page titles, e.g. "04 Jun 14:30". Kept short so it fits the Watch title.
private let watchTitleDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "dd MMM HH:mm"
    return formatter
}()

private func watchCompactStamp(_ date: Date) -> String {
    watchTitleDateFormatter.string(from: date)
}

/// One vertical page == one chat session. Swiping (up/down + Digital Crown) to the trailing empty page starts a new session.
struct WatchSessionPage: View {
    @ObservedObject var model: WatchAppModel
    let session: WatchSession
    let index: Int

    /// Hints that are not in-flight job state (those belong in the Speak button only).
    private static func isActionableStatusHint(_ hint: String) -> Bool {
        let blocked = [
            "Sending…", "Sending...", "Working…", "Recording… tap to send.",
            "Cancelled", "Failed"
        ]
        return !blocked.contains(hint)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                // watchOS truncates navigationTitle to "New" — show full agent label in-content on the main live page.
                if session.isEmpty {
                    newSessionAgentBadge
                }
                speakButton
                muteButton
                // Only pairing / permission / mic errors — send & record progress live inside the Speak button.
                if index == model.currentIndex, session.activeJob == nil, !isRecordingHere,
                   let hint = model.statusHint, Self.isActionableStatusHint(hint) {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                history
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(navigationBarTitle)
    }

    /// Top badge on the Watch main (live) screen for an empty session (compact — ~half prior size).
    private var newSessionAgentBadge: some View {
        HStack(spacing: 3) {
            Text(model.selectedAgentEmojiSymbol())
                .font(.system(size: 11))
            Text("New Session · \(model.selectedAgentTitleName())")
                .font(.system(size: 9, weight: .semibold))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 1)
    }

    /// System nav bar: empty on new session (custom badge above); dated stamp when history exists.
    private var navigationBarTitle: String {
        guard let latest = session.latestJob else { return "" }
        return "Session \(index) · \(watchCompactStamp(latest.createdAt))"
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
        .disabled(session.activeJob != nil && !isRecordingHere)
    }

    /// Per-session voice mute — hidden when iPhone has disabled "Speak replies on Watch".
    @ViewBuilder
    private var muteButton: some View {
        if model.globalTtsEnabled {
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
        }
    }
}

/// One horizontal page == one real gateway session (mirrored from the iPhone). Shows recent history and lets you keep
/// talking into THIS session via Speak. Live turns started here are tracked locally so they appear immediately.
struct GatewaySessionPage: View {
    @ObservedObject var model: WatchAppModel
    let session: WatchGatewaySession

    private var activeJob: VoiceJob? { model.gatewayActiveJob(for: session.id) }
    private var isRecordingHere: Bool { model.isRecordingGateway(session.id) }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                speakButton
                muteButton
                history
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(titleText)
    }

    /// Per-session voice mute for this gateway page — hidden when iPhone has disabled global TTS.
    @ViewBuilder
    private var muteButton: some View {
        if model.globalTtsEnabled {
            Button {
                model.toggleGatewayMute(sessionKey: session.id)
            } label: {
                Label(
                    model.isGatewayMuted(session.id) ? "Voice Off" : "Voice On",
                    systemImage: model.isGatewayMuted(session.id) ? "speaker.slash.fill" : "speaker.wave.2.fill"
                )
                .font(.caption2)
            }
            .buttonStyle(.bordered)
            .tint(model.isGatewayMuted(session.id) ? .gray : .blue)
        }
    }

    /// Small-text title: "Session · <date>" of last activity, kept short. Falls back to a plain label without a date.
    private var titleText: String {
        if let updatedAt = session.updatedAt {
            return "Session · \(watchCompactStamp(updatedAt))"
        }
        if !session.title.isEmpty, session.title != session.id { return session.title }
        return "Session"
    }

    private var speakButton: some View {
        Button {
            model.toggleGatewayRecord(sessionKey: session.id)
        } label: {
            VStack(spacing: 4) {
                if isRecordingHere {
                    Image(systemName: "stop.fill").font(.title2)
                    Text("Stop & Send").font(.caption2)
                } else if let job = activeJob {
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
        .disabled(activeJob != nil && !isRecordingHere)
    }

    @ViewBuilder
    private var history: some View {
        let turns = model.gatewayTurns(for: session.id)
        if turns.isEmpty, session.messages.isEmpty {
            Text("Tap Speak to continue this session.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                // Live turns started on this page (newest-first): agent reply above the recognized text.
                ForEach(turns) { job in
                    VStack(alignment: .leading, spacing: 2) {
                        if let result = job.resultText {
                            Text(result).font(.footnote)
                        } else if let error = job.errorMessage {
                            Text(error).font(.caption2).foregroundStyle(.red)
                        }
                        if let transcript = job.transcript {
                            Text(transcript).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Recent server history (oldest-first slice) reversed so the newest message is on top.
                ForEach(Array(session.messages.reversed())) { message in
                    Text(message.text)
                        .font(message.isUser ? .caption2 : .footnote)
                        .foregroundStyle(message.isUser ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Sessions page (one screen right of the live stack): a single vertical list of every gateway session for the
/// active agent. Scrolls down (Digital Crown) instead of paging sideways. Tapping a row opens that session.
struct GatewaySessionsListPage: View {
    @ObservedObject var model: WatchAppModel

    var body: some View {
        let sessions = model.filteredGatewaySessions
        return Group {
            if sessions.isEmpty {
                ScrollView {
                    Text("No sessions yet.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            } else {
                List {
                    ForEach(sessions) { session in
                        NavigationLink {
                            GatewaySessionPage(model: model, session: session)
                        } label: {
                            GatewaySessionListRow(session: session)
                        }
                    }
                }
            }
        }
        .navigationTitle("Sessions")
    }
}

/// Compact row for the gateway sessions list: title/preview plus a short last-activity stamp.
struct GatewaySessionListRow: View {
    let session: WatchGatewaySession

    private var rowTitle: String {
        if !session.title.isEmpty, session.title != session.id { return session.title }
        return "Session"
    }

    private var rowSubtitle: String? {
        if let preview = session.preview, !preview.isEmpty { return preview }
        if let last = session.messages.last?.text, !last.isEmpty { return last }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rowTitle)
                .font(.footnote)
                .lineLimit(1)
            if let subtitle = rowSubtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let updatedAt = session.updatedAt {
                Text(watchCompactStamp(updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Agents page (one screen left of the live stack): standard watchOS list rows.
struct AgentsPage: View {
    @ObservedObject var model: WatchAppModel

    var body: some View {
        List {
            ForEach(model.sortedAgentsForDisplay) { agent in
                Button {
                    AppLog.info("Watch agent row tapped id=\(agent.id)")
                    model.selectAgent(agent.id)
                } label: {
                    WatchAgentListRow(
                        agent: agent,
                        isSelected: model.selectedAgentId == agent.id,
                        sessionCount: model.sessionCount(forAgentId: agent.id)
                    )
                }
            }
        }
        .navigationTitle("Agents")
    }
}

/// Default-style agent row for the Watch Agents list.
struct WatchAgentListRow: View {
    let agent: WatchGatewayAgent
    let isSelected: Bool
    let sessionCount: Int

    private var displayName: String {
        agent.id == "main" ? "Main Actor" : agent.name
    }

    var body: some View {
        HStack(spacing: 8) {
            if let emoji = agent.emoji, !emoji.isEmpty {
                Text(emoji)
                    .font(.body)
            } else {
                Image(systemName: "person.circle.fill")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .lineLimit(1)
                if let subtitle = agent.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let modelLabel = agent.modelLabel, !modelLabel.isEmpty {
                    Text(modelLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if sessionCount > 0 {
                    Text("\(sessionCount) session\(sessionCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
            }
        }
    }
}

/// Usage page (left of Agents): aggregate stats derived from the gateway's session index.
struct UsagePage: View {
    @ObservedObject var model: WatchAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let usage = model.usage {
                    statRow("Agents", "\(usage.agentCount)")
                    statRow("Sessions", "\(usage.sessionCount)")
                    statRow("Total messages", "\(usage.totalMessages)")
                    statRow("Total tokens", Self.formatted(usage.totalTokens))
                    statRow("Input tokens", Self.formatted(usage.inputTokens))
                    statRow("Output tokens", Self.formatted(usage.outputTokens))
                    statRow("Avg tokens / session", Self.formatted(usage.avgTokensPerSession))
                    statRow("Last activity", Self.relativeActivity(usage.lastActivityAt))
                    if let model = usage.model { statRow("Model", model) }
                } else {
                    Text("Open the iPhone app to load usage.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .navigationTitle("Usage")
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static func formatted(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static func relativeActivity(_ date: Date?) -> String {
        guard let date else { return "—" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

struct WatchNotPairedView: View {
    @ObservedObject var model: WatchAppModel
    @State private var syncAttempts = 0

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(statusText)
                .font(.caption2)
                .multilineTextAlignment(.center)
        }
        .onAppear {
            AppLog.info("WatchNotPairedView appear phase=\(model.pairing.phase.rawValue); starting sync")
            triggerSync()
        }
        .task {
            while !Task.isCancelled, !model.isPaired {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, !model.isPaired else { break }
                syncAttempts += 1
                AppLog.info("WatchNotPairedView periodic sync attempt=\(syncAttempts)")
                triggerSync()
            }
        }
    }

    private var statusText: String {
        switch model.pairing.phase {
        case .needsSetupCode:
            return "Pair on iPhone"
        case .failed:
            return model.pairing.message ?? "Pair on iPhone"
        case .connecting, .waitingForApproval:
            return model.pairing.message ?? "Syncing with iPhone…"
        case .connected:
            return model.pairing.message ?? "Syncing with iPhone…"
        }
    }

    private func triggerSync() {
        WatchConnectivityWatchService.shared.requestSync()
    }
}
