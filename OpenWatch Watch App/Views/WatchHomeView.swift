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

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                speakButton
                muteButton
                // Only surface non-process hints (permission/pairing errors) here; live process status lives in the button.
                if index == model.currentIndex, session.activeJob == nil, !isRecordingHere, let hint = model.statusHint {
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
