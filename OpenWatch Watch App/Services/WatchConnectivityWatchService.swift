import Combine
import Foundation
import Security
import WatchConnectivity

@MainActor
final class WatchConnectivityWatchService: NSObject, ObservableObject {
    static let shared = WatchConnectivityWatchService()

    @Published private(set) var hasIPhoneInternetBridge = false

    /// True when the Watch can hand off a recorded voice note: iPhone relay, direct Watch internet, or proven iPhone WSS bridge.
    var canSendVoice: Bool {
        if hasIPhoneInternetBridge { return true }
        if WatchNetworkPathMonitor.shared.internetAvailable { return true }
        return session.activationState == .activated && session.isCompanionAppInstalled
    }

    private let session = WCSession.default
    private var pendingSyncAfterActivation = false
    private var independentWSSProbeStarted = false
    private var pendingIPhoneRelayProbeRequestId: String?

    override private init() {
        super.init()
        _ = WatchNetworkPathMonitor.shared
        if WCSession.isSupported() {
            session.delegate = self
            session.activate()
            AppLog.info("Activating WCSession on Watch")
        } else {
            AppLog.error("WCSession not supported on this Watch")
        }
    }

    // ─── Ariadne's Thread [AT-0036] ─────────────────────
    // What: FLOW-2 logs — Watch caught iPhone and internet-via-iPhone status.
    // Why:  Terminal must show step-by-step iPhone link and internet relay state.
    // Date: 2026-06-07
    // Related: [AT-0036] OpenWatchShared/FlowLog, app→WatchNetworkPathMonitor
    // ─────────────────────────────────────────────────────
    func logStep2IPhoneConnect(reason: String) {
        let companionInstalled = session.isCompanionAppInstalled
        let sessionActivated = session.activationState == .activated
        let iPhoneReachable = session.isReachable
        let caughtIPhone = companionInstalled && sessionActivated
        let liveIPhoneLink = caughtIPhone && iPhoneReachable
        let localInternet = WatchNetworkPathMonitor.shared.internetAvailable
        let internetViaIPhone = hasIPhoneInternetBridge
        let internet = WatchNetworkPathMonitor.shared.lastPathSummary

        FlowLog.started(step: 2, side: .watch, flow: "iphone-connect", detail: "reason=\(reason)")
        FlowLog.function(step: 2, side: .watch, flow: "iphone-connect", name: "WatchConnectivityWatchService.logStep2IPhoneConnect")
        FlowLog.progress(step: 2, side: .watch, flow: "iphone-connect", detail: "caughtIPhone=\(caughtIPhone) iPhoneAppInstalled=\(companionInstalled) wcSessionActivated=\(sessionActivated) iPhoneReachable=\(iPhoneReachable) liveIPhoneLink=\(liveIPhoneLink)")
        FlowLog.progress(step: 2, side: .watch, flow: "iphone-connect", detail: "iphoneConnection=\(caughtIPhone ? "caught" : "not-caught") proof=watchconnectivity localWatchInternet=\(localInternet)")
        FlowLog.result(
            step: 2,
            side: .watch,
            flow: "iphone-connect",
            success: internetViaIPhone,
            detail: "internetViaIPhone=\(internetViaIPhone) localWatchInternet=\(localInternet) path=\(internet)"
        )
        FlowLog.finished(step: 2, side: .watch, flow: "iphone-connect")
    }

    func logConnectivitySnapshot(reason: String) {
        logStep2IPhoneConnect(reason: reason)
    }

    // ─── Ariadne's Thread [AT-0041] ─────────────────────
    // What: Apply WSS hello-ok proof produced by the locked iPhone.
    // Why:  watchOS blocks general WebSocket networking; iPhone must open the WSS tunnel after WatchConnectivity wakes it.
    // Date: 2026-06-07
    // Related: [AT-0038] AppModel.publishGatewayProbeToWatch
    // ─────────────────────────────────────────────────────
    func applyGatewayProbe(reachable: Bool, detail: String?) {
        // ─── Ariadne's Thread [AT-0058] ─────────────────────
        // What: Ignore transient failed iPhone WSS probes after hello-ok was already proven.
        // Why:  Concurrent gateway refresh/probe failures can arrive after success and incorrectly gray out Speak.
        // Date: 2026-06-08
        // Related: [AT-0041] WatchConnectivityWatchService.applyGatewayProbe
        // ─────────────────────────────────────────────────────
        if !reachable, hasIPhoneInternetBridge {
            AppLog.info("Watch ignored stale gateway probe failure because WSS bridge is already proven detail=\(detail ?? "nil")")
            return
        }
        hasIPhoneInternetBridge = reachable
        FlowLog.started(step: 2, side: .watch, flow: "wss-hello", detail: "source=iphone")
        FlowLog.function(step: 2, side: .watch, flow: "wss-hello", name: "WatchConnectivityWatchService.applyGatewayProbe")
        FlowLog.progress(
            step: 2,
            side: .watch,
            flow: "wss-hello",
            detail: "gatewayProof=\(reachable ? "wss-hello-ok" : "failed") detail=\(detail ?? "nil")"
        )
        FlowLog.finished(step: 2, side: .watch, flow: "wss-hello")
        AppLog.info("Watch gateway probe applied reachable=\(reachable) detail=\(detail ?? "nil")")
    }

    // ─── Ariadne's Thread [AT-0054] ─────────────────────
    // What: Run the requested Watch direct, iPhone relay, and locked iPhone WSS probes independently.
    // Why:  Each route needs its own proof log before deciding which Watch networking path is usable.
    // Date: 2026-06-07
    // Related: [AT-0038] app→AppModel.publishGatewayProbeToWatch, [AT-0053] WatchGatewayDirectClient
    // ─────────────────────────────────────────────────────
    func runIndependentWSSProbesIfNeeded(reason: String) {
        guard !independentWSSProbeStarted else {
            AppLog.info("WSS PROBE SUITE skipped reason=\(reason); already started")
            return
        }
        independentWSSProbeStarted = true
        let suiteId = UUID().uuidString
        let localWatchInternet = WatchNetworkPathMonitor.shared.internetAvailable
        AppLog.info("WSS PROBE SUITE START suiteId=\(suiteId) reason=\(reason) localWatchInternet=\(localWatchInternet) iPhoneReachable=\(session.isReachable)")

        Task {
            let directOK = await WatchGatewayDirectClient.shared.probeRawWebSocketPing(requestId: "\(suiteId)-watch-direct")
            await MainActor.run {
                AppLog.info("WSS PROBE SUITE WATCH DIRECT RESULT suiteId=\(suiteId) localWatchInternet=\(directOK)")
            }
        }

        requestIPhoneRelayProbe(requestId: "\(suiteId)-iphone-relay")
        queueLockedIPhoneRelayProbe(requestId: "\(suiteId)-locked-iphone")
    }

    private func requestIPhoneRelayProbe(requestId: String) {
        guard session.activationState == .activated else {
            AppLog.error("IPHONE RELAY WSS sendMessage blocked requestId=\(requestId): WCSession not activated")
            return
        }
        guard session.isReachable else {
            pendingIPhoneRelayProbeRequestId = requestId
            AppLog.info("IPHONE RELAY WSS sendMessage waiting for reachable iPhone requestId=\(requestId)")
            return
        }
        let url = WatchGatewayCredentialStore.loadGatewayURL()?.absoluteString ?? ""
        let message: [String: Any] = [
            "type": "probeWSS",
            "url": url,
            "requestId": requestId,
        ]
        session.sendMessage(message, replyHandler: { reply in
            Task { @MainActor in
                let ok = reply["ok"] as? Bool ?? false
                AppLog.info("IPHONE RELAY WSS reply requestId=\(requestId) ok=\(ok) route=\(reply["route"] as? String ?? "nil") proof=\(reply["proof"] as? String ?? "nil") detail=\(reply["detail"] as? String ?? "nil")")
            }
        }, errorHandler: { error in
            Task { @MainActor in
                AppLog.error("IPHONE RELAY WSS WC failed requestId=\(requestId): \(error.localizedDescription)")
            }
        })
        AppLog.info("IPHONE RELAY WSS sendMessage sent requestId=\(requestId) iPhoneReachable=\(session.isReachable)")
    }

    private func flushPendingIPhoneRelayProbeIfReachable() {
        guard session.isReachable, let requestId = pendingIPhoneRelayProbeRequestId else { return }
        pendingIPhoneRelayProbeRequestId = nil
        AppLog.info("IPHONE RELAY WSS sendMessage starting after reachability requestId=\(requestId)")
        requestIPhoneRelayProbe(requestId: requestId)
    }

    private func queueLockedIPhoneRelayProbe(requestId: String) {
        guard session.activationState == .activated else {
            AppLog.error("LOCKED IPHONE WSS transferUserInfo blocked requestId=\(requestId): WCSession not activated")
            return
        }
        let url = WatchGatewayCredentialStore.loadGatewayURL()?.absoluteString ?? ""
        session.transferUserInfo([
            "type": "probeWSS",
            "url": url,
            "requestId": requestId,
        ])
        AppLog.info("LOCKED IPHONE WSS transferUserInfo queued requestId=\(requestId) iPhoneReachable=\(session.isReachable)")
    }

    /// Watch → iPhone commands. When the phone is reachable we send immediately (low latency); otherwise we fall back to
    /// `transferUserInfo` so iOS can wake OpenWatch in the background (phone locked / app not open).
    func sendCommand(_ envelope: WatchEnvelope) {
        guard session.activationState == .activated else {
            AppLog.error("WCSession not activated on Watch")
            return
        }
        guard let userInfo = WatchConnectivityCodec.userInfo(from: envelope) else {
            AppLog.error("Failed to encode watch command kind=\(envelope.kind.rawValue)")
            return
        }

        if session.isReachable, let data = WatchConnectivityCodec.payloadData(from: userInfo) {
            session.sendMessageData(data, replyHandler: nil) { error in
                WCSession.default.transferUserInfo(userInfo)
                Task { @MainActor in
                    AppLog.error("Watch sendMessageData failed kind=\(envelope.kind.rawValue): \(error.localizedDescription); fell back to transferUserInfo")
                }
            }
            AppLog.info("Sent command to iPhone kind=\(envelope.kind.rawValue) (immediate)")
        } else {
            session.transferUserInfo(userInfo)
            AppLog.info("Queued transferUserInfo to iPhone kind=\(envelope.kind.rawValue) (background-safe)")
        }
    }

    // ─── Ariadne's Thread [AT-0084] ─────────────────────
    // What: Send Watch-known agent, session, and message ids with missing-data requests.
    // Why:  iPhone must compute gateway deltas against the Watch cache instead of pushing full live lists.
    // Date: 2026-06-08
    // Related: [AT-0083] shared→WatchEnvelope.knownGatewayAgentIds, [AT-0069] WatchAppModel.requestMissingGatewaySessionsForSessionScreen
    // ─────────────────────────────────────────────────────
    // ─── Ariadne's Thread [AT-0100] ─────────────────────
    // What: Send screen-driven typed Watch session index and message requests.
    // Why:  The Watch reducer must receive session rows and session messages through separate payloads.
    // Date: 2026-06-08
    // Related: [AT-0099] WatchAppModel.reduceSessionsPageAppeared, [AT-0097] shared→WatchMessageKind
    // ─────────────────────────────────────────────────────
    func requestSessionIndexDelta(knownAgentIds: [String], knownSessionIds: [String], selectedAgentId: String) {
        let envelope = WatchEnvelope(
            kind: .requestSessionIndexDelta,
            pairing: WatchAppModel.shared.pairing,
            selectedAgentId: selectedAgentId,
            knownGatewayAgentIds: knownAgentIds,
            knownGatewaySessionIds: knownSessionIds
        )
        sendCommand(envelope)
        AppLog.info("Watch requested sessionIndexDelta knownAgents=\(knownAgentIds.count) knownSessions=\(knownSessionIds.count) selectedAgentId=\(selectedAgentId)")
    }

    func requestSessionMessagesDelta(
        sessionKey: String,
        knownAgentIds: [String],
        knownSessionIds: [String],
        knownMessageIds: [String],
        selectedAgentId: String
    ) {
        let envelope = WatchEnvelope(
            kind: .requestSessionMessagesDelta,
            pairing: WatchAppModel.shared.pairing,
            selectedAgentId: selectedAgentId,
            requestedSessionKey: sessionKey,
            knownGatewayAgentIds: knownAgentIds,
            knownGatewaySessionIds: knownSessionIds,
            knownGatewayMessageIdsBySession: [sessionKey: knownMessageIds]
        )
        sendCommand(envelope)
        AppLog.info("Watch requested sessionMessagesDelta sessionKey=\(sessionKey) knownMessages=\(knownMessageIds.count) knownSessions=\(knownSessionIds.count) selectedAgentId=\(selectedAgentId)")
    }

    func requestMissingGatewaySessions(
        knownAgentIds: [String],
        knownIds: [String],
        knownMessageIdsBySession: [String: [String]],
        selectedAgentId: String
    ) {
        if let sessionKey = knownMessageIdsBySession.keys.first {
            requestSessionMessagesDelta(
                sessionKey: sessionKey,
                knownAgentIds: knownAgentIds,
                knownSessionIds: knownIds,
                knownMessageIds: knownMessageIdsBySession[sessionKey] ?? [],
                selectedAgentId: selectedAgentId
            )
        } else {
            requestSessionIndexDelta(knownAgentIds: knownAgentIds, knownSessionIds: knownIds, selectedAgentId: selectedAgentId)
        }
    }

    // ─── Ariadne's Thread [AT-0024] ─────────────────────
    // What: Transfer a completed Watch audio file to the iPhone.
    // Why:  iPhone relay is the primary supported path for WSS/backend work; direct Watch WSS is only a fallback.
    // Date: 2026-06-06
    // Related: app→WatchAudioRecorder, app→WatchConnectivityPhoneService didReceive file
    // ─────────────────────────────────────────────────────
    @discardableResult
    func sendAudio(fileURL: URL, jobId: UUID, sessionKey: String) -> Bool {
        let fileBytes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? -1
        FlowLog.started(step: 5, side: .watch, flow: "audio-send-server", detail: "jobId=\(jobId) sessionKey=\(sessionKey) file=\(fileURL.lastPathComponent) bytes=\(fileBytes)")
        FlowLog.function(step: 5, side: .watch, flow: "audio-send-server", name: "WatchConnectivityWatchService.sendAudio")
        guard session.activationState == .activated else {
            FlowLog.result(step: 5, side: .watch, flow: "audio-send-server", success: false, detail: "WCSession not activated jobId=\(jobId)")
            FlowLog.finished(step: 5, side: .watch, flow: "audio-send-server")
            AppLog.error("WCSession not activated on Watch; audio file not transferred jobId=\(jobId)")
            return false
        }
        let metadata: [String: Any] = [
            "jobId": jobId.uuidString,
            "sessionKey": sessionKey,
            "fileName": fileURL.lastPathComponent,
            "mimeType": "audio/mp4",
        ]
        let transferURL: URL
        do {
            transferURL = try prepareFileForBackgroundTransfer(sourceURL: fileURL, jobId: jobId)
        } catch {
            FlowLog.result(step: 5, side: .watch, flow: "audio-send-server", success: false, detail: "prepare transfer file failed jobId=\(jobId) error=\(error.localizedDescription)")
            FlowLog.finished(step: 5, side: .watch, flow: "audio-send-server")
            AppLog.error("Watch audio file not transferred; persistent copy failed jobId=\(jobId): \(error.localizedDescription)")
            return false
        }
        let transfer = session.transferFile(transferURL, metadata: metadata)
        FlowLog.progress(step: 5, side: .watch, flow: "audio-send-server", detail: "transferFile queued to iPhone jobId=\(jobId) reachable=\(session.isReachable) outstanding=\(session.outstandingFileTransfers.count)")
        FlowLog.finished(step: 5, side: .watch, flow: "audio-send-server", detail: "handed off to iPhone jobId=\(jobId)")
        AppLog.info("Watch queued audio transferFile jobId=\(jobId) sessionKey=\(sessionKey) source=\(fileURL.lastPathComponent) transfer=\(transfer.file.fileURL.lastPathComponent) outstanding=\(session.outstandingFileTransfers.count)")
        return true
    }

    // ─── Ariadne's Thread [AT-0051] ─────────────────────
    // What: Copy Watch audio to Caches before WCSession.transferFile.
    // Why:  Locked/background iPhone delivery can happen after the recorder tmp file is no longer reliable.
    // Date: 2026-06-07
    // Related: WatchConnectivityWatchService.sendAudio, WCSessionDelegate.didFinish fileTransfer
    // ─────────────────────────────────────────────────────
    private func prepareFileForBackgroundTransfer(sourceURL: URL, jobId: UUID) throws -> URL {
        let directory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchAudioTransfers", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let targetURL = directory.appendingPathComponent("\(jobId.uuidString)-\(sourceURL.lastPathComponent)")
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: targetURL)
        let targetBytes = (try? FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? NSNumber)?.intValue ?? -1
        AppLog.info("Watch prepared persistent transfer file jobId=\(jobId) file=\(targetURL.lastPathComponent) bytes=\(targetBytes)")
        return targetURL
    }

    // ─── Ariadne's Thread [AT-0150] ─────────────────────
    // What: Ask iPhone to refresh gateway usage for the Watch Usage page.
    // Why:  Usage Retry must work without opening iPhone; cached usage stays on Watch between reboots.
    // Date: 2026-06-10
    // Related: [AT-0150] WatchAppModel.refreshUsage, AppModel.handleWatchMessage.requestUsage
    // ─────────────────────────────────────────────────────
    func requestUsage() {
        guard session.activationState == .activated else {
            AppLog.error("Watch requestUsage deferred: WCSession not activated state=\(session.activationState.rawValue)")
            return
        }
        let envelope = WatchEnvelope(
            kind: .requestUsage,
            pairing: WatchAppModel.shared.pairing
        )
        guard let userInfo = WatchConnectivityCodec.userInfo(from: envelope) else {
            AppLog.error("Watch requestUsage encode failed")
            return
        }
        session.transferUserInfo(userInfo)
        AppLog.info("Queued requestUsage to iPhone (background-safe)")
        if session.isReachable, let data = WatchConnectivityCodec.payloadData(from: userInfo) {
            session.sendMessageData(data, replyHandler: nil) { error in
                Task { @MainActor in AppLog.error("Watch requestUsage sendMessageData failed: \(error.localizedDescription); queued transferUserInfo already pending") }
            }
            AppLog.info("Sent requestUsage to iPhone (immediate)")
        }
    }

    // ─── Ariadne's Thread [AT-0151] ─────────────────────
    // What: Ask iPhone to refresh the full gateway agents list for the Watch Agents page.
    // Why:  Agents Retry must pull every configured agent from iPhone without reopening the iPhone app.
    // Date: 2026-06-10
    // Related: [AT-0151] WatchAppModel.refreshAgents, AppModel.handleWatchMessage.requestAgents
    // ─────────────────────────────────────────────────────
    func requestAgents() {
        guard session.activationState == .activated else {
            AppLog.error("Watch requestAgents deferred: WCSession not activated state=\(session.activationState.rawValue)")
            return
        }
        let envelope = WatchEnvelope(
            kind: .requestAgents,
            pairing: WatchAppModel.shared.pairing
        )
        guard let userInfo = WatchConnectivityCodec.userInfo(from: envelope) else {
            AppLog.error("Watch requestAgents encode failed")
            return
        }
        session.transferUserInfo(userInfo)
        AppLog.info("Queued requestAgents to iPhone (background-safe)")
        if session.isReachable, let data = WatchConnectivityCodec.payloadData(from: userInfo) {
            session.sendMessageData(data, replyHandler: nil) { error in
                Task { @MainActor in AppLog.error("Watch requestAgents sendMessageData failed: \(error.localizedDescription); queued transferUserInfo already pending") }
            }
            AppLog.info("Sent requestAgents to iPhone (immediate)")
        }
    }

    /// Ask the iPhone to push the current pairing + jobs snapshot back to the Watch.
    /// Uses an immediate message when the phone is reachable, otherwise queues it.
    func requestSync() {
        guard session.activationState == .activated else {
            pendingSyncAfterActivation = true
            AppLog.info("Watch requestSync deferred until WCSession activates (state=\(session.activationState.rawValue))")
            return
        }
        pendingSyncAfterActivation = false
        // Do not re-apply receivedApplicationContext here — it is often stale (old jobsSnapshot with
        // needsSetupCode) and overwrites a good connected state right after a fresh usage/agents push.
        let activeJobs = WatchAppModel.shared.activeJobsForSync()
        let envelope = WatchEnvelope(
            kind: .requestSync,
            pairing: WatchAppModel.shared.pairing,
            jobs: activeJobs.isEmpty ? nil : activeJobs,
            selectedAgentId: WatchAppModel.shared.selectedAgentIdForSync,
            knownGatewayAgentIds: WatchAppModel.shared.knownGatewayAgentIdsForSync
        )
        guard let userInfo = WatchConnectivityCodec.userInfo(from: envelope) else {
            AppLog.error("Watch requestSync encode failed")
            return
        }
        session.transferUserInfo(userInfo)
        AppLog.info("Queued requestSync to iPhone (background-safe)")
        if session.isReachable, let data = WatchConnectivityCodec.payloadData(from: userInfo) {
            session.sendMessageData(data, replyHandler: nil) { error in
                Task { @MainActor in AppLog.error("Watch requestSync sendMessageData failed: \(error.localizedDescription); queued transferUserInfo already pending") }
            }
            AppLog.info("Sent requestSync to iPhone (immediate)")
        }
    }

    // ─── Ariadne's Thread [AT-0068] ─────────────────────
    // What: Send a one-job status poll to iPhone for Retry.
    // Why:  After automatic polling expires, Retry must check the same serverJobId instead of starting a new recording.
    // Date: 2026-06-08
    // Related: [AT-0067] WatchAppModel.retryJob, [AT-0066] app→AppModel.handleWatchMessage
    // ─────────────────────────────────────────────────────
    func requestJobStatus(_ job: VoiceJob) {
        guard session.activationState == .activated else {
            pendingSyncAfterActivation = true
            AppLog.info("Watch job status retry deferred until WCSession activates jobId=\(job.id)")
            return
        }
        let envelope = WatchEnvelope(kind: .requestSync, jobId: job.id, pairing: WatchAppModel.shared.pairing, jobs: [job])
        guard let userInfo = WatchConnectivityCodec.userInfo(from: envelope) else {
            AppLog.error("Watch job status retry encode failed jobId=\(job.id)")
            return
        }
        session.transferUserInfo(userInfo)
        AppLog.info("Queued job status retry to iPhone jobId=\(job.id) serverJobId=\(job.gatewayRunId ?? "nil")")
        if session.isReachable, let data = WatchConnectivityCodec.payloadData(from: userInfo) {
            session.sendMessageData(data, replyHandler: nil) { error in
                Task { @MainActor in AppLog.error("Watch job status retry sendMessageData failed jobId=\(job.id): \(error.localizedDescription); queued transferUserInfo already pending") }
            }
            AppLog.info("Sent job status retry to iPhone jobId=\(job.id) serverJobId=\(job.gatewayRunId ?? "nil")")
        }
    }

    // ─── Ariadne's Thread [AT-0033] ─────────────────────
    // What: Apply explicit pairing revoke applicationContext even when sticky Watch cache is connected.
    // Why:  Disconnect can arrive while the Watch app is suspended; skipping all cached contexts leaves the Watch logged in.
    // Date: 2026-06-07
    // Related: [AT-0032] app→WatchConnectivityPhoneService publish, [AT-0030] app→WatchAppModel clearSessionMessageAgentUsageDataAfterPairingRevoke
    // ─────────────────────────────────────────────────────
    /// Apply the last application context once at cold start (before requestSync). Skipped when the Watch already
    /// restored a connected gateway from local cache — unless the context is an explicit pairing revoke.
    private func applyLatestApplicationContextIfNeeded() {
        let context = session.receivedApplicationContext
        guard !context.isEmpty, let data = WatchConnectivityCodec.payloadData(from: context) else {
            AppLog.info("Watch application context empty on apply; relying on local pairing cache + requestSync")
            return
        }
        if WatchAppModel.shared.shouldSkipStaleApplicationContext(),
           !Self.applicationContextContainsPairingRevoke(data) {
            AppLog.info("Watch skipping stale application context (local pairing cache is connected and context has no revoke)")
            return
        }
        AppLog.info("Applying cached application context on Watch bytes=\(data.count)")
        enqueueTransportPayload(data, source: "applicationContext-cold-start")
    }

    private static func applicationContextContainsPairingRevoke(_ data: Data) -> Bool {
        guard let envelope = try? JSONDecoder().decode(WatchEnvelope.self, from: data) else {
            AppLog.error("Watch could not inspect cached application context for pairing revoke")
            return false
        }
        let containsRevoke = envelope.revokeGatewayPairing == true
        AppLog.info("Watch inspected cached application context kind=\(envelope.kind.rawValue) revoke=\(containsRevoke)")
        return containsRevoke
    }

    fileprivate func applyLatestApplicationContextOnActivation() {
        applyLatestApplicationContextIfNeeded()
    }

    private func enqueueTransportPayload(_ data: Data, source: String, ignoreLegacyGatewaySessions: Bool = false) {
        guard let envelope = try? JSONDecoder().decode(WatchEnvelope.self, from: data) else {
            AppLog.error("Watch failed to decode transport payload source=\(source) bytes=\(data.count)")
            return
        }
        if ignoreLegacyGatewaySessions, envelope.kind == .gatewaySessions {
            AppLog.info("Watch skipped queued legacy gatewaySessions source=\(source) bytes=\(data.count); typed screen requests will reload rows/messages")
            return
        }
        AppLog.info("Watch decoded transport payload kind=\(envelope.kind.rawValue) source=\(source) bytes=\(data.count)")
        WatchAppModel.shared.send(.transportEnvelope(envelope, source: source))
    }
}

// ─── Ariadne's Thread [AT-0052] ─────────────────────
// What: Store gateway credentials on Watch for direct WSS.
// Why:  Watch must send audio straight to OpenClaw through its network route, without handing the file to the iPhone app.
// Date: 2026-06-07
// Related: WatchEnvelope.gatewayOperatorToken, WatchGatewayDirectClient
// ─────────────────────────────────────────────────────
nonisolated enum WatchGatewayCredentialStore {
    private static let service = "com.openwatchagent.watch.gateway"

    static func save(gatewayURL: String?, operatorToken: String?, operatorScopes: [String]?) {
        if let gatewayURL, !gatewayURL.isEmpty { save(key: "gatewayURL", value: gatewayURL) }
        if let operatorToken, !operatorToken.isEmpty { save(key: "operatorToken", value: operatorToken) }
        if let operatorScopes { save(key: "operatorScopes", value: operatorScopes.joined(separator: ",")) }
        AppLog.info("Watch saved gateway credentials for direct WSS hasURL=\(gatewayURL?.isEmpty == false) hasToken=\(operatorToken?.isEmpty == false) scopes=\(operatorScopes?.joined(separator: ",") ?? "unchanged")")
    }

    static func loadGatewayURL() -> URL? {
        guard let raw = load(key: "gatewayURL") else { return nil }
        return URL(string: raw)
    }

    static func loadOperatorToken() -> String? {
        load(key: "operatorToken")
    }

    static func loadOperatorScopes() -> [String] {
        guard let raw = load(key: "operatorScopes"), !raw.isEmpty else { return [] }
        return raw.split(separator: ",").map { String($0) }
    }

    static func clear() {
        delete(key: "gatewayURL")
        delete(key: "operatorToken")
        delete(key: "operatorScopes")
        AppLog.info("Watch cleared direct WSS gateway credentials")
    }

    private static func save(key: String, value: String) {
        let data = Data(value.utf8)
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

extension WatchConnectivityWatchService: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            Task { @MainActor in AppLog.error("Watch WCSession error: \(error.localizedDescription)") }
        } else {
            Task { @MainActor in
                AppLog.info("Watch WCSession activated state=\(activationState.rawValue)")
                let service = WatchConnectivityWatchService.shared
                service.logConnectivitySnapshot(reason: "wc-activated")
                if activationState == .activated {
                    service.applyLatestApplicationContextOnActivation()
                    if service.pendingSyncAfterActivation {
                        AppLog.info("Watch running deferred requestSync after activation")
                        service.requestSync()
                    }
                }
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            AppLog.info("Watch reachability changed reachable=\(session.isReachable)")
            let service = WatchConnectivityWatchService.shared
            service.logConnectivitySnapshot(reason: "iphone-reachability-changed")
            if session.isReachable {
                service.flushPendingIPhoneRelayProbeIfReachable()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor in
            AppLog.info("Watch caught iPhone message (live link) bytes=\(messageData.count)")
            WatchConnectivityWatchService.shared.logConnectivitySnapshot(reason: "iphone-live-message")
            WatchConnectivityWatchService.shared.enqueueTransportPayload(messageData, source: "sendMessageData")
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            guard let data = WatchConnectivityCodec.payloadData(from: applicationContext) else { return }
            WatchConnectivityWatchService.shared.enqueueTransportPayload(data, source: "applicationContext")
        }
    }

    /// Queued iPhone → Watch commands (e.g. remote-start recording) arrive here when the Watch app was not reachable.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            if userInfo["type"] as? String == "probeWSSResult" {
                let requestId = userInfo["requestId"] as? String ?? "nil"
                let ok = userInfo["ok"] as? Bool ?? false
                AppLog.info("LOCKED IPHONE WSS result requestId=\(requestId) ok=\(ok) route=\(userInfo["route"] as? String ?? "nil") detail=\(userInfo["detail"] as? String ?? "nil")")
                return
            }
            guard let data = WatchConnectivityCodec.payloadData(from: userInfo) else { return }
            AppLog.info("Watch caught iPhone message (queued transferUserInfo) bytes=\(data.count)")
            WatchConnectivityWatchService.shared.logConnectivitySnapshot(reason: "iphone-queued-message")
            WatchConnectivityWatchService.shared.enqueueTransportPayload(data, source: "transferUserInfo", ignoreLegacyGatewaySessions: true)
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let metadata = fileTransfer.file.metadata ?? [:]
        let jobId = metadata["jobId"] as? String ?? "nil"
        let fileURL = fileTransfer.file.fileURL
        Task { @MainActor in
            if let error {
                FlowLog.result(step: 5, side: .watch, flow: "audio-send-server", success: false, detail: "transferFile failed jobId=\(jobId) error=\(error.localizedDescription)")
                AppLog.error("Watch transferFile finished with error jobId=\(jobId) file=\(fileURL.lastPathComponent): \(error.localizedDescription)")
            } else {
                FlowLog.progress(step: 5, side: .watch, flow: "audio-send-server", detail: "transferFile delivered to iPhone jobId=\(jobId) file=\(fileURL.lastPathComponent)")
                AppLog.info("Watch transferFile delivered to iPhone jobId=\(jobId) file=\(fileURL.lastPathComponent)")
            }
            try? FileManager.default.removeItem(at: fileURL)
            AppLog.info("Watch removed transfer file jobId=\(jobId) file=\(fileURL.lastPathComponent)")
        }
    }
}

nonisolated enum WatchGatewayDirectError: LocalizedError {
    case notPaired
    case missingOperatorToken
    case invalidWebSocketURL
    case challengeTimeout
    case connectFailed(String)
    case runFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notPaired:
            return "Not connected to a gateway. Pair on iPhone first."
        case .missingOperatorToken:
            return "Missing operator token on Watch. Open iPhone app once to sync credentials."
        case .invalidWebSocketURL:
            return "Gateway WebSocket URL is invalid."
        case .challengeTimeout:
            return "Gateway did not send a connect challenge."
        case .connectFailed(let reason):
            return "Gateway connect failed: \(reason)"
        case .runFailed(let reason):
            return "Agent run failed: \(reason)"
        case .timedOut:
            return "Agent did not respond in time."
        }
    }
}

// ─── Ariadne's Thread [AT-0053] ─────────────────────
// What: Send Watch audio directly to OpenClaw over WSS.
// Why:  Locked iPhone can provide network routing, but the iPhone app cannot be relied on for immediate file handoff.
// Date: 2026-06-07
// Related: WatchGatewayCredentialStore, WatchAppModel.sendSavedAudioFileDirectToGateway
// ─────────────────────────────────────────────────────
actor WatchGatewayDirectClient {
    static let shared = WatchGatewayDirectClient()

    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let stallTimeoutSeconds: TimeInterval = 90

    func probeGatewayHelloOk() async -> String {
        do {
            let task = try await openOperatorSocket()
            task.cancel(with: .goingAway, reason: nil)
            AppLog.info("Watch direct WSS probe succeeded: connect.challenge -> connect -> hello-ok")
            return "wss hello-ok"
        } catch {
            AppLog.error("Watch direct WSS probe failed: \(error.localizedDescription)")
            return "error=\(error.localizedDescription)"
        }
    }

    func probeRawWebSocketPing(requestId: String) async -> Bool {
        do {
            guard let gatewayURL = WatchGatewayCredentialStore.loadGatewayURL() else {
                AppLog.error("WATCH DIRECT WSS FAILED requestId=\(requestId): missing gateway URL")
                return false
            }
            let wsURL = try websocketURL(from: gatewayURL)
            let task = URLSession.shared.webSocketTask(with: wsURL)
            task.resume()
            defer { task.cancel(with: .normalClosure, reason: nil) }
            try await sendPing(on: task, timeoutSeconds: 10)
            AppLog.info("WATCH DIRECT WSS OK requestId=\(requestId) url=\(wsURL.absoluteString)")
            return true
        } catch {
            AppLog.error("WATCH DIRECT WSS FAILED requestId=\(requestId): \(error.localizedDescription)")
            return false
        }
    }

    func runAudioAttachment(
        audioData: Data,
        fileName: String,
        mimeType: String,
        sessionKey: String,
        idempotencyKey: String,
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        AppLog.info("Watch direct WSS opening sessionKey=\(sessionKey) bytes=\(audioData.count) fileName=\(fileName) mimeType=\(mimeType)")
        let task = try await openOperatorSocket()
        defer { task.cancel(with: .goingAway, reason: nil) }

        try await sendSessionMessagesSubscribe(on: task, sessionKey: sessionKey)

        let chatSendId = UUID().uuidString
        try await sendChatSend(
            on: task,
            chatSendId: chatSendId,
            sessionKey: sessionKey,
            message: "",
            idempotencyKey: idempotencyKey,
            attachments: [[
                "type": "audio",
                "fileName": fileName,
                "mimeType": mimeType,
                "content": audioData.base64EncodedString(),
            ]]
        )
        AppLog.info("Watch direct WSS chat.send dispatched sessionKey=\(sessionKey) id=\(chatSendId)")
        onProgress("Sent audio. Transcribing…")

        let reply = try await waitForReply(on: task, sessionKey: sessionKey, chatSendId: chatSendId, onProgress: onProgress)
        AppLog.info("Watch direct WSS reply received length=\(reply.count) sessionKey=\(sessionKey)")
        return reply
    }

    private func openOperatorSocket() async throws -> URLSessionWebSocketTask {
        guard let gatewayURL = WatchGatewayCredentialStore.loadGatewayURL() else {
            AppLog.error("Watch direct WSS blocked: missing gateway URL")
            throw WatchGatewayDirectError.notPaired
        }
        guard let operatorToken = WatchGatewayCredentialStore.loadOperatorToken() else {
            AppLog.error("Watch direct WSS blocked: missing operator token")
            throw WatchGatewayDirectError.missingOperatorToken
        }
        let operatorScopes = WatchGatewayCredentialStore.loadOperatorScopes()
        let identity = try DeviceIdentityStore.loadOrCreate()
        let wsURL = try websocketURL(from: gatewayURL)
        let task = URLSession.shared.webSocketTask(with: wsURL)
        task.resume()

        let nonce = try await waitForChallenge(on: task)
        AppLog.info("Watch direct WSS received connect.challenge")
        let connectId = UUID().uuidString
        try await sendConnect(
            on: task,
            connectId: connectId,
            identity: identity,
            operatorToken: operatorToken,
            operatorScopes: operatorScopes,
            nonce: nonce
        )
        try await waitForHelloOk(on: task, connectId: connectId)
        AppLog.info("Watch direct WSS hello-ok")
        return task
    }

    private func sendSessionMessagesSubscribe(on task: URLSessionWebSocketTask, sessionKey: String) async throws {
        try await sendJSON([
            "type": "req",
            "id": UUID().uuidString,
            "method": "sessions.messages.subscribe",
            "params": ["key": sessionKey],
        ], on: task)
    }

    private func fetchHistory(sessionKey: String) async throws -> [[String: Any]] {
        let task = try await openOperatorSocket()
        defer { task.cancel(with: .goingAway, reason: nil) }
        let reqId = UUID().uuidString
        try await sendJSON([
            "type": "req",
            "id": reqId,
            "method": "chat.history",
            "params": ["sessionKey": sessionKey],
        ], on: task)
        let payload = try await awaitResult(on: task, id: reqId)
        return (payload["messages"] as? [[String: Any]])
            ?? (payload["items"] as? [[String: Any]])
            ?? (payload["history"] as? [[String: Any]])
            ?? []
    }

    private func awaitResult(on task: URLSessionWebSocketTask, id: String) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let json = try await receiveJSON(on: task, timeoutSeconds: min(deadline.timeIntervalSinceNow, 15))
            guard (json["type"] as? String) == "res", (json["id"] as? String) == id else { continue }
            if (json["ok"] as? Bool) == false {
                let error = json["error"] as? [String: Any]
                let message = (error?["message"] as? String) ?? (error?["code"] as? String) ?? "request failed"
                throw WatchGatewayDirectError.runFailed(message)
            }
            return (json["payload"] as? [String: Any]) ?? [:]
        }
        throw WatchGatewayDirectError.timedOut
    }

    private func sendConnect(
        on task: URLSessionWebSocketTask,
        connectId: String,
        identity: DeviceIdentityMaterial,
        operatorToken: String,
        operatorScopes: [String],
        nonce: String
    ) async throws {
        let signedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        let signaturePayload = DeviceAuthPayloadBuilder.buildV2(
            deviceId: identity.deviceId,
            clientId: GatewayClientProfile.clientId,
            clientMode: GatewayClientProfile.operatorMode,
            role: GatewayClientProfile.operatorRole,
            scopes: operatorScopes,
            signedAtMs: signedAtMs,
            token: operatorToken,
            nonce: nonce
        )
        let signature = try identity.sign(payload: signaturePayload)
        try await sendJSON([
            "type": "req",
            "id": connectId,
            "method": "connect",
            "params": [
                "minProtocol": 3,
                "maxProtocol": 4,
                "client": [
                    "id": GatewayClientProfile.clientId,
                    "version": appVersion,
                    "platform": "watchos",
                    "mode": GatewayClientProfile.operatorMode,
                ],
                "role": GatewayClientProfile.operatorRole,
                "scopes": operatorScopes,
                "caps": [] as [String],
                "commands": [] as [String],
                "permissions": [:] as [String: Bool],
                "auth": ["deviceToken": operatorToken],
                "locale": Locale.current.identifier,
                "userAgent": GatewayClientProfile.userAgent(appVersion: appVersion),
                "device": [
                    "id": identity.deviceId,
                    "publicKey": identity.publicKeyBase64URL,
                    "signature": signature,
                    "signedAt": signedAtMs,
                    "nonce": nonce,
                ],
            ],
        ], on: task)
    }

    private func sendChatSend(
        on task: URLSessionWebSocketTask,
        chatSendId: String,
        sessionKey: String,
        message: String,
        idempotencyKey: String,
        attachments: [[String: Any]]
    ) async throws {
        try await sendJSON([
            "type": "req",
            "id": chatSendId,
            "method": "chat.send",
            "params": [
                "sessionKey": sessionKey,
                "message": message,
                "idempotencyKey": idempotencyKey,
                "deliver": false,
                "attachments": attachments,
            ],
        ], on: task)
    }

    private func waitForReply(
        on task: URLSessionWebSocketTask,
        sessionKey: String,
        chatSendId: String,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        var latestText = ""
        var lastProgress = ""

        func emit(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != lastProgress else { return }
            lastProgress = trimmed
            onProgress(trimmed)
        }

        while true {
            let json: [String: Any]
            do {
                json = try await receiveJSON(on: task, timeoutSeconds: stallTimeoutSeconds)
            } catch {
                AppLog.error("Watch direct WSS stalled with no frames for \(stallTimeoutSeconds)s")
                throw WatchGatewayDirectError.timedOut
            }

            AppLog.info("Watch direct WSFRAME \(describeFrame(json))")
            if (json["type"] as? String) == "res", (json["id"] as? String) == chatSendId, (json["ok"] as? Bool) == false {
                let error = json["error"] as? [String: Any]
                let message = (error?["message"] as? String) ?? (error?["code"] as? String) ?? "chat.send rejected"
                throw WatchGatewayDirectError.runFailed(message)
            }

            guard (json["type"] as? String) == "event", let event = json["event"] as? String else { continue }
            let payload = json["payload"] as? [String: Any] ?? [:]

            if event == "session.message",
               eventSessionKey(payload) == nil || eventSessionKey(payload) == sessionKey,
               let finalText = extractAssistantText(from: payload),
               !finalText.isEmpty {
                return finalText
            }

            if event == "agent", eventSessionKey(payload) == sessionKey, isCompletedAgentMessage(payload) {
                let messages = try await fetchHistory(sessionKey: sessionKey)
                if let finalText = messages.last(where: { row in
                    (row["role"] as? String) == "assistant" && historyText(from: row) != nil
                }).flatMap({ historyText(from: $0) })?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !finalText.isEmpty {
                    return finalText
                }
                throw WatchGatewayDirectError.runFailed("Agent returned an empty response.")
            }

            if event == "session.operation" || event == "session.tool" || event == "session.message" || event == "agent" {
                if eventSessionKey(payload) == nil || eventSessionKey(payload) == sessionKey,
                   let step = progressString(event: event, payload: payload) {
                    emit(step)
                }
                continue
            }

            guard event == "chat", (payload["sessionKey"] as? String) == sessionKey else { continue }
            if let text = extractAssistantText(from: payload) {
                latestText = text
            }
            switch (payload["state"] as? String) ?? "" {
            case "delta":
                emit("Responding…")
            case "final":
                let finalText = extractAssistantText(from: payload) ?? latestText
                guard !finalText.isEmpty else { throw WatchGatewayDirectError.runFailed("Agent returned an empty response.") }
                return finalText
            case "error":
                let message = (payload["errorMessage"] as? String) ?? "Agent run failed."
                throw WatchGatewayDirectError.runFailed(message)
            default:
                continue
            }
        }
    }

    private func waitForHelloOk(on task: URLSessionWebSocketTask, connectId: String) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let json = try await receiveJSON(on: task, timeoutSeconds: 15)
            guard (json["type"] as? String) == "res", (json["id"] as? String) == connectId else { continue }
            if (json["ok"] as? Bool) == true,
               let payload = json["payload"] as? [String: Any],
               (payload["type"] as? String) == "hello-ok" {
                return
            }
            if let error = json["error"] as? [String: Any] {
                let message = (error["message"] as? String) ?? (error["code"] as? String) ?? "unknown"
                throw WatchGatewayDirectError.connectFailed(message)
            }
            throw WatchGatewayDirectError.connectFailed("Unexpected connect response")
        }
        throw WatchGatewayDirectError.connectFailed("Handshake timed out")
    }

    private func waitForChallenge(on task: URLSessionWebSocketTask) async throws -> String {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let message = try await task.receive()
            switch message {
            case .string(let text):
                guard
                    let data = text.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    (json["event"] as? String) == "connect.challenge",
                    let payload = json["payload"] as? [String: Any],
                    let nonce = payload["nonce"] as? String
                else { continue }
                return nonce
            case .data:
                continue
            @unknown default:
                continue
            }
        }
        throw WatchGatewayDirectError.challengeTimeout
    }

    private func sendJSON(_ object: [String: Any], on task: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await task.send(.string(text))
    }

    private func sendPing(on task: URLSessionWebSocketTask, timeoutSeconds: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    task.sendPing { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw WatchGatewayDirectError.timedOut
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func receiveJSON(on task: URLSessionWebSocketTask, timeoutSeconds: TimeInterval) async throws -> [String: Any] {
        let message = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw WatchGatewayDirectError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        let text: String
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            text = String(data: data, encoding: .utf8) ?? ""
        @unknown default:
            text = ""
        }
        guard
            let data = text.data(using: .utf8),
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw WatchGatewayDirectError.runFailed("Malformed gateway frame")
        }
        return json
    }

    private func websocketURL(from gatewayURL: URL) throws -> URL {
        var components = URLComponents()
        components.scheme = gatewayURL.scheme == "wss" || gatewayURL.scheme == "https" ? "wss" : "ws"
        components.host = gatewayURL.host
        components.port = gatewayURL.port
        components.path = gatewayURL.path.isEmpty ? "/" : gatewayURL.path
        guard let url = components.url else { throw WatchGatewayDirectError.invalidWebSocketURL }
        return url
    }

    private func describeFrame(_ json: [String: Any]) -> String {
        let type = (json["type"] as? String) ?? "?"
        let event = (json["event"] as? String) ?? ""
        let id = (json["id"] as? String) ?? ""
        var payloadString = ""
        if let payload = json["payload"],
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let raw = String(data: data, encoding: .utf8) {
            payloadString = raw.count > 600 ? String(raw.prefix(600)) + "…" : raw
        }
        return "type=\(type) event=\(event) id=\(id) payload=\(payloadString)"
    }

    private func eventSessionKey(_ payload: [String: Any]) -> String? {
        if let key = payload["sessionKey"] as? String { return key }
        if let session = payload["session"] as? [String: Any], let key = session["key"] as? String { return key }
        return nil
    }

    private func isCompletedAgentMessage(_ payload: [String: Any]) -> Bool {
        guard let data = payload["data"] as? [String: Any] else { return false }
        let type = (data["type"] as? String) ?? (data["kind"] as? String)
        let phase = (data["phase"] as? String) ?? (data["status"] as? String)
        return type == "agentMessage" && phase == "completed"
    }

    private func progressString(event: String, payload: [String: Any]) -> String? {
        func firstString(_ keys: [String]) -> String? {
            for key in keys {
                if let value = payload[key] as? String, !value.isEmpty { return value }
            }
            return nil
        }
        switch event {
        case "session.tool":
            let name = firstString(["tool", "name", "toolName", "title", "label"]) ?? "tool"
            let status = firstString(["status", "state", "phase"])
            return status != nil ? "Tool: \(name) (\(status!))" : "Tool: \(name)"
        case "session.operation":
            let label = firstString(["label", "title", "kind", "operation", "name", "type"]) ?? "operation"
            let status = firstString(["status", "state", "phase"])
            return status != nil ? "\(label) (\(status!))" : label
        case "agent":
            if let status = firstString(["status", "state", "phase"]) { return "Agent: \(status)" }
            return "Working…"
        default:
            return nil
        }
    }

    // ─── Ariadne's Thread [AT-0118] ─────────────────────
    // What: Accept only assistant text-block payloads from direct Watch OpenClaw history/events.
    // Why:  Tool calls/results and user messages are not bot replies and must not reach Watch UI state.
    // Date: 2026-06-09
    // Related: app→GatewayJobClient.parseHistory, WatchConnectivityWatchService.waitForReply
    // ─────────────────────────────────────────────────────
    private func extractAssistantText(from payload: [String: Any]) -> String? {
        let source = (payload["message"] as? [String: Any]) ?? payload
        guard (source["role"] as? String) == "assistant" else { return nil }
        return historyText(from: source)
    }

    private func historyText(from row: [String: Any]) -> String? {
        if let message = row["message"] as? [String: Any] { return historyText(from: message) }
        guard (row["role"] as? String) == "assistant",
              let blocks = row["content"] as? [[String: Any]] else {
            return nil
        }
        let parts = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text",
                  let text = block["text"] as? String else {
                return nil
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : text
        }
        let joined = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}
