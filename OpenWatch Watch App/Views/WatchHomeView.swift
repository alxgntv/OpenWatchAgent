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
    @ObservedObject private var connectivity = WatchConnectivityWatchService.shared
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

    // ─── Ariadne's Thread [AT-0034] ─────────────────────
    // What: Hide navigation bar title on Watch main (live) screen.
    // Why:  Title and top badge wasted vertical space; content should start at the top.
    // Date: 2026-06-07
    // Related: [AT-0002] WatchAppModel horizontalIndex main screen
    // ─────────────────────────────────────────────────────
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
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
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            guard index == model.currentIndex, model.horizontalIndex == 2 else { return }
            FlowLog.function(step: 1, side: .watch, flow: "main-screen", name: "WatchSessionPage.onAppear")
            FlowLog.finished(step: 1, side: .watch, flow: "main-screen", detail: "sessionIndex=\(index)")
        }
    }

    /// Recording is global (one recorder) and always belongs to the visible session, so it only shows on the current page.
    private var isRecordingHere: Bool {
        model.isRecording && index == model.currentIndex
    }

    private var retryJob: VoiceJob? {
        session.retryJob
    }

    private var isWaitingForIPhoneInternet: Bool {
        !connectivity.hasIPhoneInternetBridge && !isRecordingHere && session.activeJob == nil && retryJob == nil
    }

    @ViewBuilder
    private var history: some View {
        if session.jobs.isEmpty {
            Text("Speak with your \(model.selectedAgentEmojiSymbol()) \(model.selectedAgentTitleName())")
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
            if let retryJob {
                model.retryJob(retryJob)
            } else {
                model.toggleRecord()
            }
        } label: {
            VStack(spacing: 4) {
                if isRecordingHere {
                    Image(systemName: "stop.fill").font(.title2)
                    Text("Stop & Send").font(.caption2)
                } else if retryJob != nil {
                    Image(systemName: "arrow.clockwise").font(.title2)
                    Text("Retry").font(.caption2)
                } else if let job = session.activeJob {
                    // Already sent to work in this session: spinner replaces the mic and the live status is the label.
                    ProgressView()
                    Text(job.statusDetail ?? "Working…")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                } else if isWaitingForIPhoneInternet {
                    Image(systemName: "wifi.slash").font(.title2)
                    Text("Waiting Interent").font(.caption2)
                } else {
                    Image(systemName: "mic.fill").font(.title2)
                    Text("Speak").font(.caption2)
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(isRecordingHere ? .red : (isWaitingForIPhoneInternet ? .gray : .blue))
        .disabled((session.activeJob != nil && !isRecordingHere) || isWaitingForIPhoneInternet)
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
    @ObservedObject private var connectivity = WatchConnectivityWatchService.shared
    let sessionKey: String

    // ─── Ariadne's Thread [AT-0116] ─────────────────────
    // What: Make each Watch session detail refreshable and show a loading state for missing texts.
    // Why:  Opened sessions must support native pull-to-refresh and avoid showing empty copy while messages are loading.
    // Date: 2026-06-09
    // Related: [AT-0115] WatchAppModel.refreshSessionMessages, [AT-0094] WatchAppModel.gatewayMessagesBySessionKey
    // ─────────────────────────────────────────────────────
    private var detailState: SessionDetailState {
        model.sessionDetailState(for: sessionKey)
    }

    private var sessionMessages: [WatchHistoryMessage] {
        detailState.messages
    }

    private var activeJob: VoiceJob? { model.gatewayActiveJob(for: sessionKey) }
    private var retryJob: VoiceJob? { model.gatewayRetryJob(for: sessionKey) }
    private var isRecordingHere: Bool { model.isRecordingGateway(sessionKey) }
    private var isWaitingForIPhoneInternet: Bool {
        !connectivity.hasIPhoneInternetBridge && !isRecordingHere && activeJob == nil && retryJob == nil
    }

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
        .refreshable {
            await model.refreshSessionMessages(sessionKey: sessionKey)
        }
        .onAppear {
            model.send(.sessionDetailAppeared(sessionKey: sessionKey))
        }
    }

    /// Per-session voice mute for this gateway page — hidden when iPhone has disabled global TTS.
    @ViewBuilder
    private var muteButton: some View {
        if model.globalTtsEnabled {
            Button {
                model.toggleGatewayMute(sessionKey: sessionKey)
            } label: {
                Label(
                    model.isGatewayMuted(sessionKey) ? "Voice Off" : "Voice On",
                    systemImage: model.isGatewayMuted(sessionKey) ? "speaker.slash.fill" : "speaker.wave.2.fill"
                )
                .font(.caption2)
            }
            .buttonStyle(.bordered)
            .tint(model.isGatewayMuted(sessionKey) ? .gray : .blue)
        }
    }

    /// Small-text title: "Session · <date>" of last activity, kept short. Falls back to a plain label without a date.
    private var titleText: String {
        if let updatedAt = detailState.updatedAt {
            return "Session · \(watchCompactStamp(updatedAt))"
        }
        if !detailState.title.isEmpty, detailState.title != sessionKey { return detailState.title }
        return "Session"
    }

    private var speakButton: some View {
        Button {
            if let retryJob {
                model.retryJob(retryJob)
            } else {
                model.toggleGatewayRecord(sessionKey: sessionKey)
            }
        } label: {
            VStack(spacing: 4) {
                if isRecordingHere {
                    Image(systemName: "stop.fill").font(.title2)
                    Text("Stop & Send").font(.caption2)
                } else if retryJob != nil {
                    Image(systemName: "arrow.clockwise").font(.title2)
                    Text("Retry").font(.caption2)
                } else if let job = activeJob {
                    ProgressView()
                    Text(job.statusDetail ?? "Working…")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                } else if isWaitingForIPhoneInternet {
                    Image(systemName: "wifi.slash").font(.title2)
                    Text("Waiting Interent").font(.caption2)
                } else {
                    Image(systemName: "mic.fill").font(.title2)
                    Text("Speak").font(.caption2)
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(isRecordingHere ? .red : (isWaitingForIPhoneInternet ? .gray : .blue))
        .disabled((activeJob != nil && !isRecordingHere) || isWaitingForIPhoneInternet)
    }

    @ViewBuilder
    private var history: some View {
        let state = detailState
        let turns = state.liveJobs
        let messages = sessionMessages
        if state.isLoading, turns.isEmpty, messages.isEmpty {
            VStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Loading messages…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
        } else if turns.isEmpty, messages.isEmpty {
            Text("Speak with your \(model.selectedAgentEmojiSymbol()) \(model.selectedAgentTitleName())")
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
                ForEach(Array(messages.reversed())) { message in
                    Text(message.text)
                        .font(message.isUser ? .caption2 : .footnote)
                        .foregroundStyle(message.isUser ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// ─── Ariadne's Thread [AT-0112] ─────────────────────
// What: Rebuild the Watch Sessions page as a refreshable scroll view with tappable cards.
// Why:  Pulling down on Sessions must natively request missing iPhone-backed sessions for the current agent.
// Date: 2026-06-09
// Related: [AT-0110] WatchAppModel.refreshSessionsForCurrentAgent, [AT-0097] shared→WatchSessionIndexDelta
// ─────────────────────────────────────────────────────
/// Sessions page (one screen right of the live stack): a single vertical list of every gateway session for the
/// active agent. Scrolls down (Digital Crown) instead of paging sideways. Tapping a row opens that session.
struct GatewaySessionsListPage: View {
    @ObservedObject var model: WatchAppModel

    var body: some View {
        let state = model.sessionListState
        let sessions = state.rows
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if sessions.isEmpty {
                    VStack(spacing: 8) {
                        if state.isLoading {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                        Text(state.isLoading ? "Loading sessions…" : "No sessions yet.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    ForEach(sessions) { session in
                        NavigationLink {
                            GatewaySessionPage(model: model, sessionKey: session.id)
                        } label: {
                            GatewaySessionListRow(session: session)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
        }
        .navigationTitle("Sessions")
        .refreshable {
            await model.refreshSessionsForCurrentAgent()
        }
        .onAppear {
            model.send(.sessionsPageAppeared(agentId: state.selectedAgentId))
        }
    }
}

/// Compact card for the gateway sessions list: newest text first plus a short last-activity stamp.
struct GatewaySessionListRow: View {
    let session: SessionListRowState

    private var rowPrimaryText: String {
        if let preview = session.preview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty { return preview }
        if !session.title.isEmpty, session.title != session.id { return session.title }
        return "Session"
    }

    private var rowSecondaryText: String? {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != session.id, title != rowPrimaryText else { return nil }
        return title
    }

    private var activityText: String? {
        if let updatedAt = session.updatedAt {
            return watchCompactStamp(updatedAt)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(rowPrimaryText)
                    .font(.footnote)
                    .lineLimit(1)
                if session.hasActiveJob {
                    ProgressView()
                        .scaleEffect(0.55)
                }
            }
            if let subtitle = rowSecondaryText {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let activityText {
                Text(activityText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// ─── Ariadne's Thread [AT-0102] ─────────────────────
// What: Render agents from AgentsListState and send tap events instead of selecting directly.
// Why:  Selecting an agent must not mutate agent rows inside a watchOS List tap transaction.
// Date: 2026-06-08
// Related: [AT-0099] app→WatchAppModel.reduceAgentTapped, [AT-0098] app→AgentsListState
// ─────────────────────────────────────────────────────
/// Agents page (one screen left of the live stack): standard watchOS list rows.
struct AgentsPage: View {
    @ObservedObject var model: WatchAppModel
    @Binding var selection: String?

    var body: some View {
        let state = model.agentsListState
        List(state.rows, selection: $selection) { agent in
            WatchAgentListRow(
                agent: agent,
                isSelected: selection == agent.id
            )
            .tag(agent.id)
            .onAppear {
                AppLog.info("Watch agent row rendered id=\(agent.id)")
            }
        }
        .navigationTitle("Agents")
        .onAppear {
            model.send(.agentsPageAppeared)
        }
    }
}

/// Default-style agent row for the Watch Agents list.
struct WatchAgentListRow: View {
    let agent: AgentListRowState
    let isSelected: Bool

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
                } else if agent.sessionCount > 0 {
                    Text("\(agent.sessionCount) session\(agent.sessionCount == 1 ? "" : "s")")
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
