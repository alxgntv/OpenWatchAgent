import Combine
import Foundation
import WatchConnectivity

@MainActor
final class WatchConnectivityPhoneService: NSObject, ObservableObject {
    static let shared = WatchConnectivityPhoneService()

    private let session = WCSession.default

    // ─── Ariadne's Thread [AT-0001] ─────────────────────
    // What: Cache last pairing/TTS snapshot for every Watch applicationContext push.
    // Why:  updateApplicationContext replaces the whole payload; gatewaySessions-only pushes
    //       dropped pairing so the Watch cold-started into "Pair on iPhone" after battery drain.
    // Date: 2026-06-04
    // Related: WatchAppModel pairing cache, WatchConnectivityWatchService requestSync
    // ─────────────────────────────────────────────────────
    private var cachedPairingForWatch: PairingSnapshot?
    private var cachedTtsEnabledForWatch: Bool?
    private var cachedTtsLanguageForWatch: String?

    /// True only when the Watch app is currently reachable (its app is active/foreground). The iPhone cannot launch
    /// the Watch app itself — watchOS provides no such API — so commands only take effect while this is true.
    var isWatchReachable: Bool {
        session.activationState == .activated && session.isReachable
    }

    override private init() {
        super.init()
        if WCSession.isSupported() {
            session.delegate = self
            session.activate()
            AppLog.info("Activating WCSession on iPhone")
        }
    }

    func publish(
        pairing: PairingSnapshot,
        jobs: [VoiceJob],
        ttsEnabled: Bool,
        ttsLanguage: String,
        revokeGatewayPairing: Bool = false
    ) {
        let outbound = revokeGatewayPairing ? pairing : Self.pairingForWatchOutbound(pairing)
        cachedPairingForWatch = outbound
        cachedTtsEnabledForWatch = ttsEnabled
        cachedTtsLanguageForWatch = ttsLanguage
        AppLog.info("Cached Watch pairing phase=\(outbound.phase.rawValue) revoke=\(revokeGatewayPairing) for context enrichment")
        guard session.activationState == .activated else {
            AppLog.info("WCSession not activated on iPhone; pairing cached but push deferred")
            return
        }
        let envelope = WatchEnvelope(
            kind: .jobsSnapshot,
            pairing: outbound,
            jobs: jobs,
            ttsEnabled: ttsEnabled,
            ttsLanguage: ttsLanguage,
            revokeGatewayPairing: revokeGatewayPairing ? true : nil
        )
        pushToWatch(envelope, preferImmediate: true)
    }

    /// While Keychain still has gateway credentials, never push needsSetupCode/failed to the Watch (sticky pairing).
    private static func pairingForWatchOutbound(_ pairing: PairingSnapshot) -> PairingSnapshot {
        guard KeychainStore.isPaired,
              pairing.phase != .connected,
              let url = KeychainStore.loadGatewayURL()?.absoluteString else {
            return pairing
        }
        AppLog.info("Normalized outbound Watch pairing \(pairing.phase.rawValue) -> connected (keychain still paired)")
        return PairingSnapshot(
            phase: .connected,
            gatewayURL: url,
            message: pairing.message ?? "Connected.",
            deviceId: pairing.deviceId
        )
    }

    func publish(job: VoiceJob) {
        guard session.activationState == .activated else { return }
        let envelope = WatchEnvelope(kind: .jobUpdated, job: job)
        pushToWatch(envelope, preferImmediate: true)
        // Background-safe delivery: when the Watch app is suspended/closed (wrist down, screen off) it is not
        // reachable, so the immediate sendMessageData above is dropped and only the latest applicationContext survives.
        // Queue every job update via transferUserInfo too — watchOS persists this queue and delivers it (via
        // didReceiveUserInfo) as soon as the Watch app wakes, so the status/result catches up without a manual reopen.
        guard let userInfo = WatchConnectivityCodec.userInfo(from: envelope) else {
            AppLog.error("Failed to encode job update for transferUserInfo jobId=\(job.id)")
            return
        }
        session.transferUserInfo(userInfo)
        AppLog.info("Queued job update to Watch via transferUserInfo jobId=\(job.id) status=\(job.status.rawValue) (background-safe)")
    }

    /// Pushes the real gateway session index (with recent history) so the Watch can show horizontal session pages.
    func publishGatewaySessions(_ sessions: [WatchGatewaySession]) {
        guard session.activationState == .activated else { return }
        let envelope = WatchEnvelope(kind: .gatewaySessions, gatewaySessions: sessions)
        pushToWatch(envelope, preferImmediate: true)
        AppLog.info("Pushed \(sessions.count) gateway sessions to Watch")
    }

    /// Pushes aggregate usage (session count, tokens, model) to the Watch's Usage page.
    func publishUsage(_ usage: WatchUsage) {
        guard session.activationState == .activated else { return }
        let envelope = WatchEnvelope(kind: .usage, usage: usage)
        pushToWatch(envelope, preferImmediate: true)
        AppLog.info("Pushed usage to Watch agents=\(usage.agentCount) sessions=\(usage.sessionCount) totalTokens=\(usage.totalTokens)")
    }

    /// Pushes configured gateway agents and the active selection to the Watch's Agents page.
    func publishAgents(_ agents: [WatchGatewayAgent], selectedAgentId: String) {
        guard session.activationState == .activated else { return }
        let envelope = WatchEnvelope(kind: .agents, gatewayAgents: agents, selectedAgentId: selectedAgentId)
        pushToWatch(envelope, preferImmediate: true)
        AppLog.info("Pushed \(agents.count) agents to Watch selectedAgentId=\(selectedAgentId)")
    }

    /// iPhone → Watch command (e.g. remote-start a recording). Delivered immediately when the Watch app is reachable,
    /// otherwise queued via transferUserInfo (the Watch can only act on it once its app is active — watchOS limitation).
    func sendCommandToWatch(_ envelope: WatchEnvelope) {
        guard session.activationState == .activated else {
            AppLog.error("WCSession not activated on iPhone; cannot send command kind=\(envelope.kind.rawValue)")
            return
        }
        guard let userInfo = WatchConnectivityCodec.userInfo(from: envelope) else {
            AppLog.error("Failed to encode iPhone->Watch command kind=\(envelope.kind.rawValue)")
            return
        }
        if session.isReachable, let data = WatchConnectivityCodec.payloadData(from: userInfo) {
            session.sendMessageData(data, replyHandler: nil) { error in
                WCSession.default.transferUserInfo(userInfo)
                Task { @MainActor in
                    AppLog.error("iPhone sendMessageData to Watch failed kind=\(envelope.kind.rawValue): \(error.localizedDescription); fell back to transferUserInfo")
                }
            }
            AppLog.info("Sent command to Watch kind=\(envelope.kind.rawValue) (immediate)")
        } else {
            session.transferUserInfo(userInfo)
            AppLog.info("Queued command to Watch kind=\(envelope.kind.rawValue) (background-safe)")
        }
    }

    /// Merges cached pairing/TTS into every outbound context so the Watch never loses connected state on partial updates.
    private func enrichWatchEnvelope(_ envelope: WatchEnvelope) -> WatchEnvelope {
        let mergedPairing: PairingSnapshot?
        if envelope.revokeGatewayPairing == true {
            mergedPairing = envelope.pairing ?? cachedPairingForWatch
        } else if let explicit = envelope.pairing {
            mergedPairing = Self.pairingForWatchOutbound(explicit)
        } else if let cached = cachedPairingForWatch {
            mergedPairing = Self.pairingForWatchOutbound(cached)
        } else {
            mergedPairing = nil
        }
        let enriched = WatchEnvelope(
            kind: envelope.kind,
            jobId: envelope.jobId,
            pairing: mergedPairing,
            job: envelope.job,
            jobs: envelope.jobs,
            text: envelope.text,
            ttsEnabled: envelope.ttsEnabled ?? cachedTtsEnabledForWatch,
            ttsLanguage: envelope.ttsLanguage ?? cachedTtsLanguageForWatch,
            gatewaySessions: envelope.gatewaySessions,
            usage: envelope.usage,
            gatewayAgents: envelope.gatewayAgents,
            selectedAgentId: envelope.selectedAgentId,
            revokeGatewayPairing: envelope.revokeGatewayPairing
        )
        if enriched.pairing == nil, cachedPairingForWatch == nil {
            AppLog.info("Watch context enrich kind=\(envelope.kind.rawValue) has no cached pairing yet")
        } else if envelope.pairing == nil, let cached = cachedPairingForWatch {
            AppLog.info("Watch context enrich kind=\(envelope.kind.rawValue) attached cached pairing phase=\(cached.phase.rawValue)")
        }
        return enriched
    }

    private func pushToWatch(_ envelope: WatchEnvelope, preferImmediate: Bool) {
        let enriched = enrichWatchEnvelope(envelope)
        guard let context = WatchConnectivityCodec.applicationContext(from: enriched) else { return }
        do {
            try session.updateApplicationContext(context)
            AppLog.info("Pushed application context to Watch kind=\(enriched.kind.rawValue) pairingPhase=\(enriched.pairing?.phase.rawValue ?? "nil")")
        } catch {
            AppLog.error("applicationContext update failed: \(error.localizedDescription)")
        }

        guard preferImmediate, session.isReachable, let data = context[WatchConnectivityCodec.payloadKey] as? Data else { return }
        session.sendMessageData(data, replyHandler: nil) { error in
            AppLog.error("WCSession send to Watch failed: \(error.localizedDescription)")
        }
    }

    private func deliverWatchCommand(_ data: Data, source: String) {
        AppLog.info("Delivering watch command source=\(source) bytes=\(data.count)")
        Task { @MainActor in
            BackgroundTaskService.begin("watchVoiceCommand")
            await AppModel.shared.handleWatchMessage(data)
            BackgroundTaskService.end()
        }
    }
}

extension WatchConnectivityPhoneService: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            Task { @MainActor in AppLog.error("WCSession activation error: \(error.localizedDescription)") }
        } else {
            Task { @MainActor in
                AppLog.info("WCSession activated state=\(activationState.rawValue)")
                if activationState == .activated {
                    AppModel.shared.republishToWatch(reason: "phone-wc-activated")
                }
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            AppLog.info("iPhone reachability changed reachable=\(session.isReachable)")
            if session.isReachable {
                AppModel.shared.republishToWatch(reason: "watch-reachable")
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor in
            deliverWatchCommand(messageData, source: "sendMessageData")
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            guard let data = WatchConnectivityCodec.payloadData(from: userInfo) else { return }
            deliverWatchCommand(data, source: "transferUserInfo")
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata ?? [:]
        let isAudio = (metadata[WatchConnectivityCodec.audioKindKey] as? Bool) ?? false
        let jobIdString = metadata[WatchConnectivityCodec.audioJobIdKey] as? String
        let sessionKey = metadata[WatchConnectivityCodec.audioSessionKeyKey] as? String

        // The incoming file is deleted once this method returns, so copy it to our own temp location first (synchronously).
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString).m4a")
        let copied: Bool
        do {
            try FileManager.default.copyItem(at: file.fileURL, to: dest)
            copied = true
        } catch {
            copied = false
            Task { @MainActor in AppLog.error("Failed to copy received watch audio: \(error.localizedDescription)") }
        }

        Task { @MainActor in
            guard copied, isAudio, let jobIdString, let jobId = UUID(uuidString: jobIdString) else {
                AppLog.error("Received file without valid audio metadata; ignoring")
                try? FileManager.default.removeItem(at: dest)
                return
            }
            let resolvedSessionKey = sessionKey ?? "agent:main:main"
            AppLog.info("iPhone received watch audio jobId=\(jobId) sessionKey=\(resolvedSessionKey) bytes=\((try? Data(contentsOf: dest))?.count ?? 0)")
            BackgroundTaskService.begin("watchVoiceAudio")
            await AppModel.shared.handleWatchAudio(jobId: jobId, fileURL: dest, sessionKey: resolvedSessionKey)
            BackgroundTaskService.end()
        }
    }

}
