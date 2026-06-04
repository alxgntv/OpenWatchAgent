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
        .navigationTitle(titleText)
    }

    /// Small-text title: "New" for the empty page, otherwise "Session N · <date>" of the latest turn.
    private var titleText: String {
        guard let latest = session.latestJob else { return "New" }
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

    /// Per-session voice mute for this gateway page. Tapping it while a reply is speaking also stops it immediately.
    /// Disabled (and shown off) when the iPhone has turned voice off globally.
    private var muteButton: some View {
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
        .disabled(!model.globalTtsEnabled)
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
        .disabled(activeJob != nil)
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

/// Agents page (one screen left of the live stack): Workout-style cards mirrored from the iPhone.
struct AgentsPage: View {
    @ObservedObject var model: WatchAppModel

    private let accent = Color(red: 0.75, green: 0.95, blue: 0.2)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("AGENTS")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(accent)
                ForEach(model.sortedAgentsForDisplay) { agent in
                    Button {
                        AppLog.info("Watch agent card tapped id=\(agent.id)")
                        model.selectAgent(agent.id)
                    } label: {
                        WatchAgentCardView(
                            agent: agent,
                            isSelected: model.selectedAgentId == agent.id,
                            sessionCount: model.sessionCount(forAgentId: agent.id),
                            accent: accent
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
        .navigationTitle("Agents")
    }
}

/// Compact Workout-style agent tile for watchOS.
struct WatchAgentCardView: View {
    let agent: WatchGatewayAgent
    let isSelected: Bool
    let sessionCount: Int
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let emoji = agent.emoji, !emoji.isEmpty {
                    Text(emoji).font(.title3)
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundStyle(accent)
                }
                Spacer(minLength: 4)
                Image(systemName: "ellipsis")
                    .font(.caption2)
                    .foregroundStyle(accent.opacity(0.8))
            }
            Text(agent.name)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(subtitleText)
                .font(.caption2.weight(.bold))
                .foregroundStyle(accent)
                .lineLimit(2)
            if sessionCount > 0 {
                Text("\(sessionCount) session\(sessionCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.14)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? accent : Color.clear, lineWidth: 2)
        )
    }

    private var subtitleText: String {
        if let model = agent.modelLabel, !model.isEmpty {
            return model.replacingOccurrences(of: "/", with: " · ").uppercased()
        }
        if let subtitle = agent.subtitle, !subtitle.isEmpty {
            return String(subtitle.prefix(32)).uppercased()
        }
        return agent.isDefault ? "DEFAULT" : "AGENT"
    }
}

/// Usage page (left of Agents): aggregate stats derived from the gateway's session index.
struct UsagePage: View {
    @ObservedObject var model: WatchAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Usage").font(.headline)
                if let usage = model.usage {
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
