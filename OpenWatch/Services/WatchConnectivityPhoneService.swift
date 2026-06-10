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
    private var cachedHapticTypeForWatch: String?
    private var cachedTtsRateForWatch: Double?
    private var cachedLaunchGreetingPhraseForWatch: String?
    private var cachedLaunchGreetingLanguageForWatch: String?
    private var cachedLaunchGreetingVoiceIdentifierForWatch: String?
    private var cachedGatewayOperatorTokenForWatch: String?
    private var cachedGatewayOperatorScopesForWatch: [String]?
    private var deliveredGatewaySessionSnapshots: [String: WatchGatewaySession] = [:]
    private var deliveredUsageSnapshot: WatchUsage?
    private var deliveredAgentsSnapshot: [WatchGatewayAgent] = []
    private var deliveredSelectedAgentId: String?

    /// True only when the Watch app is currently reachable (its app is active/foreground). The iPhone cannot launch
    /// the Watch app itself — watchOS provides no such API — so commands only take effect while this is true.
    var isWatchReachable: Bool {
        session.activationState == .activated && session.isReachable
    }

    override private init() {
        super.init()
        _ = PhoneNetworkPathMonitor.shared
        if WCSession.isSupported() {
            session.delegate = self
            session.activate()
            AppLog.info("Activating WCSession on iPhone")
        }
    }

    private func logStep2IPhoneConnect(reason: String) {
        let sessionActivated = session.activationState == .activated
        let watchReachable = session.isReachable
        let caughtWatch = sessionActivated && watchReachable
        let internet = PhoneNetworkPathMonitor.shared.internetAvailable
        FlowLog.started(step: 2, side: .iphone, flow: "iphone-connect", detail: "reason=\(reason)")
        FlowLog.function(step: 2, side: .iphone, flow: "iphone-connect", name: "WatchConnectivityPhoneService.logStep2IPhoneConnect")
        FlowLog.progress(step: 2, side: .iphone, flow: "iphone-connect", detail: "caughtWatch=\(caughtWatch) watchReachable=\(watchReachable) wcSessionActivated=\(sessionActivated)")
        FlowLog.result(
            step: 2,
            side: .iphone,
            flow: "iphone-connect",
            success: internet,
            detail: "internetAvailable=\(internet) path=\(PhoneNetworkPathMonitor.shared.lastPathSummary)"
        )
        FlowLog.finished(step: 2, side: .iphone, flow: "iphone-connect")
    }

    // ─── Ariadne's Thread [AT-0032] ─────────────────────
    // What: Queue explicit Watch pairing revoke snapshots through transferUserInfo.
    // Why:  Disconnect must reach the Watch even when its app is suspended and cannot receive immediate messages.
    // Date: 2026-06-07
    // Related: [AT-0001] app→WatchConnectivityPhoneService enrichWatchEnvelope, [AT-0030] app→WatchAppModel clearSessionMessageAgentUsageDataAfterPairingRevoke
    // ─────────────────────────────────────────────────────
    func publish(
        pairing: PairingSnapshot,
        jobs: [VoiceJob],
        ttsEnabled: Bool,
        ttsLanguage: String,
        hapticType: String,
        ttsRate: Double,
        launchGreetingPhrase: String,
        launchGreetingLanguage: String,
        launchGreetingVoiceIdentifier: String,
        revokeGatewayPairing: Bool = false
    ) {
        let outbound = revokeGatewayPairing ? pairing : Self.pairingForWatchOutbound(pairing)
        cachedPairingForWatch = outbound
        cachedTtsEnabledForWatch = ttsEnabled
        cachedTtsLanguageForWatch = ttsLanguage
        cachedHapticTypeForWatch = hapticType
        cachedTtsRateForWatch = ttsRate
        cachedLaunchGreetingPhraseForWatch = launchGreetingPhrase
        cachedLaunchGreetingLanguageForWatch = launchGreetingLanguage
        cachedLaunchGreetingVoiceIdentifierForWatch = launchGreetingVoiceIdentifier
        cachedGatewayOperatorTokenForWatch = KeychainStore.loadOperatorToken()
        cachedGatewayOperatorScopesForWatch = KeychainStore.loadOperatorScopes()
        AppLog.info("Cached Watch pairing phase=\(outbound.phase.rawValue) haptic=\(hapticType) rate=\(ttsRate) revoke=\(revokeGatewayPairing) for context enrichment")
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
            hapticType: hapticType,
            ttsRate: ttsRate,
            launchGreetingPhrase: launchGreetingPhrase,
            launchGreetingLanguage: launchGreetingLanguage,
            launchGreetingVoiceIdentifier: launchGreetingVoiceIdentifier,
            revokeGatewayPairing: revokeGatewayPairing ? true : nil,
            gatewayOperatorToken: revokeGatewayPairing ? nil : cachedGatewayOperatorTokenForWatch,
            gatewayOperatorScopes: revokeGatewayPairing ? nil : cachedGatewayOperatorScopesForWatch
        )
        pushToWatch(envelope, preferImmediate: true)
        if revokeGatewayPairing {
            queueSnapshotToWatch(envelope, label: "pairingRevoke")
        }
    }

    /// While Keychain still has gateway credentials, never push needsSetupCode/failed to the Watch (sticky pairing).
    private static func pairingForWatchOutbound(_ pairing: PairingSnapshot) -> PairingSnapshot {
        if !KeychainStore.isPaired, pairing.phase == .connected {
            AppLog.info("Normalized outbound Watch pairing connected -> needsSetupCode (gateway Keychain no longer paired)")
            return PairingSnapshot(
                phase: .needsSetupCode,
                message: "Enter a new setup code.",
                deviceId: pairing.deviceId
            )
        }
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

    // ─── Ariadne's Thread [AT-0104] ─────────────────────
    // What: Publish typed Watch deltas for agents, session index, and session messages.
    // Why:  Watch UI needs rows and messages delivered as separate reducer events, not one gatewaySessions container.
    // Date: 2026-06-08
    // Related: [AT-0097] shared→WatchSessionIndexDelta, [AT-0099] watch→WatchAppModel.reduceTransportEnvelope
    // ─────────────────────────────────────────────────────
    func publishSessionIndexDelta(_ delta: WatchSessionIndexDelta, force: Bool = false) {
        guard session.activationState == .activated else { return }
        guard force || !delta.sessions.isEmpty else {
            AppLog.info("Skipped Watch sessionIndexDelta: empty")
            return
        }
        let envelope = WatchEnvelope(kind: .sessionIndexDelta, sessionIndexDelta: delta)
        pushToWatch(envelope, preferImmediate: true)
        AppLog.info("Pushed sessionIndexDelta to Watch rows=\(delta.sessions.count) selectedAgentId=\(delta.selectedAgentId ?? "nil")")
    }

    func publishSessionMessagesDelta(_ delta: WatchSessionMessagesDelta, force: Bool = false) {
        guard session.activationState == .activated else { return }
        guard force || !delta.messages.isEmpty else {
            AppLog.info("Skipped Watch sessionMessagesDelta: empty sessionKey=\(delta.sessionKey)")
            return
        }
        let envelope = WatchEnvelope(kind: .sessionMessagesDelta, sessionMessagesDelta: delta)
        pushToWatch(envelope, preferImmediate: true)
        AppLog.info("Pushed sessionMessagesDelta to Watch sessionKey=\(delta.sessionKey) messages=\(delta.messages.count)")
    }

    /// Legacy adapter: splits any gateway session container into typed session index and message deltas.
    func publishGatewaySessions(_ sessions: [WatchGatewaySession], replace: Bool = true, force: Bool = false) {
        guard session.activationState == .activated else { return }
        let sessionsToSend: [WatchGatewaySession]
        // ─── Ariadne's Thread [AT-0077] ─────────────────────
        // What: Let forced gatewaySessions deltas bypass the delivered-session filter.
        // Why:  A Watch screen request must receive message deltas even if the iPhone delivery cache thinks the session was already sent.
        // Date: 2026-06-08
        // Related: [AT-0074] app→AppModel.publishMissingGatewaySessionsToWatch
        // ─────────────────────────────────────────────────────
        if replace || force {
            sessionsToSend = sessions
        } else {
            sessionsToSend = sessions.filter { deliveredGatewaySessionSnapshots[$0.id] != $0 }
        }
        guard force || replace || !sessionsToSend.isEmpty else {
            AppLog.info("Skipped Watch gatewaySessions snapshot: no changed or missing sessions")
            return
        }
        let rows = sessionsToSend.map { WatchSessionRow(session: $0) }
        publishSessionIndexDelta(WatchSessionIndexDelta(selectedAgentId: nil, sessions: rows), force: force || replace)
        for item in sessionsToSend where !item.messages.isEmpty {
            publishSessionMessagesDelta(
                WatchSessionMessagesDelta(sessionKey: item.id, messages: item.messages),
                force: force
            )
        }
        // ─── Ariadne's Thread [AT-0090] ─────────────────────
        // What: Keep gatewaySessions off transferUserInfo, including deltas.
        // Why:  Queued session payloads can arrive during startup while Watch SwiftUI lists are mounted; sessions are requested only from the opened screen.
        // Date: 2026-06-08
        // Related: [AT-0086] WatchConnectivityPhoneService.pushToWatch, [AT-0072] watch→WatchConnectivityWatchService.didReceiveUserInfo
        // ─────────────────────────────────────────────────────
        AppLog.info("Skipped queued legacy gatewaySessions snapshot; typed Watch screen requests own sessions/messages")
        if replace {
            deliveredGatewaySessionSnapshots = [:]
            for session in sessions {
                deliveredGatewaySessionSnapshots[session.id] = session
            }
        } else {
            for item in sessionsToSend {
                deliveredGatewaySessionSnapshots[item.id] = item
            }
        }
        AppLog.info("Adapted \(sessionsToSend.count) gateway sessions to typed Watch deltas replace=\(replace) sourceCount=\(sessions.count)")
    }

    /// Pushes aggregate usage (session count, tokens, model) to the Watch's Usage page.
    func publishUsage(_ usage: WatchUsage, force: Bool = false) {
        guard session.activationState == .activated else { return }
        guard force || deliveredUsageSnapshot != usage else {
            AppLog.info("Skipped Watch usage snapshot: unchanged")
            return
        }
        let envelope = WatchEnvelope(kind: .usage, usage: usage)
        pushToWatch(envelope, preferImmediate: true)
        queueSnapshotToWatch(envelope, label: "usage")
        deliveredUsageSnapshot = usage
        AppLog.info("Pushed usage to Watch agents=\(usage.agentCount) sessions=\(usage.sessionCount) totalTokens=\(usage.totalTokens)")
    }

    /// Pushes configured gateway agents and the active selection to the Watch's Agents page.
    func publishAgents(_ agents: [WatchGatewayAgent], selectedAgentId: String, force: Bool = false, fullSnapshot: Bool = false) {
        guard session.activationState == .activated else { return }
        guard force || deliveredAgentsSnapshot != agents || deliveredSelectedAgentId != selectedAgentId else {
            AppLog.info("Skipped Watch agents snapshot: unchanged")
            return
        }
        let envelope = WatchEnvelope(
            kind: .agentIndexDelta,
            agentIndexDelta: WatchAgentIndexDelta(agents: agents, selectedAgentId: selectedAgentId, isFullSnapshot: fullSnapshot ? true : nil)
        )
        pushToWatch(envelope, preferImmediate: true)
        // ─── Ariadne's Thread [AT-0091] ─────────────────────
        // What: Queue Watch agent deltas through transferUserInfo after switching to cache-first merge.
        // Why:  Missing-agent and selected-agent replies must survive reachability gaps; Watch now merges by id instead of replacing the live list.
        // Date: 2026-06-08
        // Related: [AT-0085] watch→WatchAppModel.mergeGatewayAgentDelta, [AT-0089] app→AppModel.cacheWatchAgentsPayload
        // ─────────────────────────────────────────────────────
        queueSnapshotToWatch(envelope, label: "agentsDelta")
        deliveredAgentsSnapshot = agents
        deliveredSelectedAgentId = selectedAgentId
        AppLog.info("Pushed agentIndexDelta to Watch agents=\(agents.count) selectedAgentId=\(selectedAgentId) fullSnapshot=\(fullSnapshot)")
    }

    func resetSessionMessageAgentUsageDeliveryCache() {
        deliveredGatewaySessionSnapshots = [:]
        deliveredUsageSnapshot = nil
        deliveredAgentsSnapshot = []
        deliveredSelectedAgentId = nil
        AppLog.info("Reset Watch sessions/messages/agents/usage delivery cache")
    }

    // ─── Ariadne's Thread [AT-0028] ─────────────────────
    // What: Persist sessions, messages, agents, and usage Watch snapshots through transferUserInfo.
    // Why:  applicationContext keeps only the latest envelope, so sessions/usage/agents can be overwritten before Watch wakes.
    // Date: 2026-06-06
    // Related: [AT-0001] app→WatchConnectivityPhoneService enrichWatchEnvelope, app→WatchAppModel applyEnvelope
    // ─────────────────────────────────────────────────────
    private func queueSnapshotToWatch(_ envelope: WatchEnvelope, label: String) {
        let enriched = enrichWatchEnvelope(envelope)
        guard let userInfo = WatchConnectivityCodec.userInfo(from: enriched) else {
            AppLog.error("Failed to encode Watch \(label) snapshot for transferUserInfo")
            return
        }
        session.transferUserInfo(userInfo)
        AppLog.info("Queued Watch \(label) snapshot via transferUserInfo kind=\(enriched.kind.rawValue)")
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
            hapticType: envelope.hapticType ?? cachedHapticTypeForWatch,
            ttsRate: envelope.ttsRate ?? cachedTtsRateForWatch,
            launchGreetingPhrase: envelope.launchGreetingPhrase ?? cachedLaunchGreetingPhraseForWatch,
            launchGreetingLanguage: envelope.launchGreetingLanguage ?? cachedLaunchGreetingLanguageForWatch,
            launchGreetingVoiceIdentifier: envelope.launchGreetingVoiceIdentifier ?? cachedLaunchGreetingVoiceIdentifierForWatch,
            gatewaySessions: envelope.gatewaySessions,
            replaceGatewaySessions: envelope.replaceGatewaySessions,
            usage: envelope.usage,
            gatewayAgents: envelope.gatewayAgents,
            selectedAgentId: envelope.selectedAgentId,
            revokeGatewayPairing: envelope.revokeGatewayPairing,
            gatewayReachable: envelope.gatewayReachable,
            gatewayProbeDetail: envelope.gatewayProbeDetail,
            gatewayOperatorToken: envelope.gatewayOperatorToken ?? cachedGatewayOperatorTokenForWatch,
            gatewayOperatorScopes: envelope.gatewayOperatorScopes ?? cachedGatewayOperatorScopesForWatch,
            agentIndexDelta: envelope.agentIndexDelta,
            sessionIndexDelta: envelope.sessionIndexDelta,
            sessionMessagesDelta: envelope.sessionMessagesDelta,
            requestedSessionKey: envelope.requestedSessionKey,
            knownGatewayAgentIds: envelope.knownGatewayAgentIds,
            knownGatewaySessionIds: envelope.knownGatewaySessionIds,
            knownGatewayMessageIdsBySession: envelope.knownGatewayMessageIdsBySession
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
        guard let context = WatchConnectivityCodec.applicationContext(from: enriched),
              let data = context[WatchConnectivityCodec.payloadKey] as? Data else { return }
        // ─── Ariadne's Thread [AT-0086] ─────────────────────
        // What: Exclude agents and gateway sessions from Watch applicationContext updates.
        // Why:  These payloads are bound to Watch SwiftUI lists and must arrive as Watch-requested deltas, not full live replacements.
        // Date: 2026-06-08
        // Related: [AT-0085] watch→WatchAppModel.mergeGatewayAgentDelta, [AT-0075] watch→WatchAppModel.replaceGatewaySessionsPreservingMessages
        // ─────────────────────────────────────────────────────
        if enriched.kind == .gatewaySessions || enriched.kind == .agents || enriched.kind == .agentIndexDelta || enriched.kind == .sessionIndexDelta || enriched.kind == .sessionMessagesDelta {
            AppLog.info("Skipped application context for \(enriched.kind.rawValue) bytes=\(data.count); using immediate missing-data delta sync only")
        } else {
            do {
                try session.updateApplicationContext(context)
                AppLog.info("Pushed application context to Watch kind=\(enriched.kind.rawValue) pairingPhase=\(enriched.pairing?.phase.rawValue ?? "nil")")
            } catch {
                AppLog.error("applicationContext update failed: \(error.localizedDescription)")
            }
        }

        guard preferImmediate, session.isReachable else { return }
        session.sendMessageData(data, replyHandler: nil) { error in
            AppLog.error("WCSession send to Watch failed: \(error.localizedDescription)")
        }
    }

    // ─── Ariadne's Thread [AT-0056] ─────────────────────
    // What: Handle Watch-requested live and queued iPhone WSS relay probes.
    // Why:  The Watch needs separate proof for sendMessage relay and locked-phone transferUserInfo relay.
    // Date: 2026-06-07
    // Related: [AT-0054] watch→WatchConnectivityWatchService.runIndependentWSSProbesIfNeeded, [AT-0055] app→AppModel.probeWSSForWatchRelay
    // ─────────────────────────────────────────────────────
    private func handleProbeWSSMessage(_ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["type"] as? String == "probeWSS" else {
            replyHandler(["ok": false, "route": "iphone-relay", "proof": "failed", "detail": "unsupported-message"])
            return
        }
        let requestId = message["requestId"] as? String ?? UUID().uuidString
        AppLog.info("IPHONE RELAY WSS sendMessage received requestId=\(requestId) url=\(message["url"] as? String ?? "nil")")
        Task { @MainActor in
            let reply = await AppModel.shared.probeWSSForWatchRelay(requestId: requestId, route: "iphone-relay")
            replyHandler(reply)
        }
    }

    private func handleProbeWSSUserInfo(_ userInfo: [String: Any]) {
        guard userInfo["type"] as? String == "probeWSS" else { return }
        let requestId = userInfo["requestId"] as? String ?? UUID().uuidString
        AppLog.info("LOCKED IPHONE WSS transferUserInfo received requestId=\(requestId) url=\(userInfo["url"] as? String ?? "nil")")
        Task { @MainActor in
            var reply = await AppModel.shared.probeWSSForWatchRelay(requestId: requestId, route: "iphone-relay")
            reply["type"] = "probeWSSResult"
            self.session.transferUserInfo(reply)
            AppLog.info("LOCKED IPHONE WSS result queued to Watch requestId=\(requestId) ok=\(reply["ok"] as? Bool ?? false) detail=\(reply["detail"] as? String ?? "nil")")
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
                    WatchConnectivityPhoneService.shared.logStep2IPhoneConnect(reason: "wc-activated")
                    AppModel.shared.republishToWatch(reason: "phone-wc-activated")
                }
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            AppLog.info("iPhone reachability changed reachable=\(session.isReachable)")
            WatchConnectivityPhoneService.shared.logStep2IPhoneConnect(reason: "watch-reachability-changed")
            if session.isReachable {
                AppModel.shared.republishToWatch(reason: "watch-reachable")
                Task { await AppModel.shared.publishGatewayProbeToWatch(reason: "watch-reachable") }
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

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            WatchConnectivityPhoneService.shared.handleProbeWSSMessage(message, replyHandler: replyHandler)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            if userInfo["type"] as? String == "probeWSS" {
                WatchConnectivityPhoneService.shared.handleProbeWSSUserInfo(userInfo)
                return
            }
            guard let data = WatchConnectivityCodec.payloadData(from: userInfo) else { return }
            deliverWatchCommand(data, source: "transferUserInfo")
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata ?? [:]
        let jobIdString = metadata["jobId"] as? String
        let sessionKey = metadata["sessionKey"] as? String
        let fileName = (metadata["fileName"] as? String) ?? file.fileURL.lastPathComponent
        let mimeType = (metadata["mimeType"] as? String) ?? "audio/mp4"
        let copiedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-\(UUID().uuidString)-\(fileName)")
        do {
            try FileManager.default.copyItem(at: file.fileURL, to: copiedURL)
        } catch {
            Task { @MainActor in
                FlowLog.result(step: 5, side: .iphone, flow: "audio-send-server", success: false, detail: "copy transferFile failed error=\(error.localizedDescription)")
                FlowLog.finished(step: 5, side: .iphone, flow: "audio-send-server")
                AppLog.error("Failed to copy Watch audio transferFile source=\(file.fileURL.lastPathComponent) target=\(copiedURL.lastPathComponent): \(error.localizedDescription)")
            }
            return
        }
        Task { @MainActor in
            guard let jobIdString, let jobId = UUID(uuidString: jobIdString) else {
                FlowLog.result(step: 5, side: .iphone, flow: "audio-send-server", success: false, detail: "missing jobId in transferFile metadata file=\(file.fileURL.lastPathComponent)")
                AppLog.error("Received Watch audio file without valid jobId metadata file=\(file.fileURL.lastPathComponent)")
                try? FileManager.default.removeItem(at: copiedURL)
                return
            }
            let targetSessionKey = (sessionKey?.isEmpty == false) ? sessionKey! : "agent:main:main"
            let fileBytes = (try? FileManager.default.attributesOfItem(atPath: copiedURL.path)[.size] as? NSNumber)?.intValue ?? -1
            FlowLog.started(step: 5, side: .iphone, flow: "audio-send-server", detail: "jobId=\(jobId) sessionKey=\(targetSessionKey) file=\(fileName) bytes=\(fileBytes)")
            FlowLog.function(step: 5, side: .iphone, flow: "audio-send-server", name: "WatchConnectivityPhoneService.didReceiveFile")
            FlowLog.progress(step: 5, side: .iphone, flow: "audio-send-server", detail: "received transferFile from Watch mimeType=\(mimeType) internetAvailable=\(PhoneNetworkPathMonitor.shared.internetAvailable)")
            let jobLogId = String(jobId.uuidString.prefix(3))
            AppLog.info("[IPHONE][JOB \(jobLogId)] file received jobId=\(jobId) sessionKey=\(targetSessionKey) file=\(fileName) bytes=\(fileBytes) mimeType=\(mimeType)")
            AppLog.info("Received Watch audio transferFile jobId=\(jobId) sessionKey=\(targetSessionKey) file=\(fileName) mimeType=\(mimeType)")
            BackgroundTaskService.begin("watchAudioFile")
            await AppModel.shared.handleWatchAudioFile(
                fileURL: copiedURL,
                jobId: jobId,
                sessionKey: targetSessionKey,
                fileName: fileName,
                mimeType: mimeType
            )
            BackgroundTaskService.end()
        }
    }

}
