import Combine
import Foundation
import WatchConnectivity

@MainActor
final class WatchConnectivityWatchService: NSObject, ObservableObject {
    static let shared = WatchConnectivityWatchService()

    private let session = WCSession.default
    private var pendingSyncAfterActivation = false

    override private init() {
        super.init()
        if WCSession.isSupported() {
            session.delegate = self
            session.activate()
            AppLog.info("Activating WCSession on Watch")
        }
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

    /// Transfers a recorded voice file to the iPhone. The iPhone transcribes it and forwards the text to the gateway.
    /// Uses `transferFile`, which is delivered reliably (in the background too) and carries metadata natively.
    func sendAudio(fileURL: URL, jobId: UUID, sessionKey: String) {
        guard session.activationState == .activated else {
            AppLog.error("WCSession not activated on Watch; cannot send audio")
            return
        }
        let metadata: [String: Any] = [
            WatchConnectivityCodec.audioKindKey: true,
            WatchConnectivityCodec.audioJobIdKey: jobId.uuidString,
            WatchConnectivityCodec.audioSessionKeyKey: sessionKey,
        ]
        session.transferFile(fileURL, metadata: metadata)
        AppLog.info("Watch transferFile audio jobId=\(jobId) sessionKey=\(sessionKey) file=\(fileURL.lastPathComponent)")
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
        applyLatestApplicationContext()
        let envelope = WatchEnvelope(kind: .requestSync)
        if session.isReachable, let data = WatchConnectivityCodec.payloadData(from: WatchConnectivityCodec.userInfo(from: envelope) ?? [:]) {
            session.sendMessageData(data, replyHandler: nil) { error in
                Task { @MainActor in AppLog.error("Watch requestSync sendMessageData failed: \(error.localizedDescription)") }
            }
            AppLog.info("Sent requestSync to iPhone (immediate)")
        } else {
            sendCommand(envelope)
            AppLog.info("Queued requestSync to iPhone (background-safe)")
        }
    }

    /// Apply the last application context the iPhone published, so the Watch shows known state immediately on launch.
    private func applyLatestApplicationContext() {
        let context = session.receivedApplicationContext
        guard !context.isEmpty, let data = WatchConnectivityCodec.payloadData(from: context) else {
            AppLog.info("Watch application context empty on apply; relying on local pairing cache + requestSync")
            return
        }
        AppLog.info("Applying cached application context on Watch bytes=\(data.count)")
        WatchAppModel.shared.applyEnvelope(data)
    }

    fileprivate func applyLatestApplicationContextOnActivation() {
        applyLatestApplicationContext()
    }
}

extension WatchConnectivityWatchService: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            Task { @MainActor in AppLog.error("Watch WCSession error: \(error.localizedDescription)") }
        } else {
            Task { @MainActor in
                AppLog.info("Watch WCSession activated state=\(activationState.rawValue)")
                if activationState == .activated {
                    let service = WatchConnectivityWatchService.shared
                    service.applyLatestApplicationContextOnActivation()
                    if service.pendingSyncAfterActivation {
                        AppLog.info("Watch running deferred requestSync after activation")
                    }
                    service.requestSync()
                }
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            AppLog.info("Watch reachability changed reachable=\(session.isReachable)")
            if session.isReachable {
                WatchConnectivityWatchService.shared.requestSync()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor in
            WatchAppModel.shared.applyEnvelope(messageData)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            guard let data = WatchConnectivityCodec.payloadData(from: applicationContext) else { return }
            WatchAppModel.shared.applyEnvelope(data)
        }
    }

    /// Queued iPhone → Watch commands (e.g. remote-start recording) arrive here when the Watch app was not reachable.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            guard let data = WatchConnectivityCodec.payloadData(from: userInfo) else { return }
            AppLog.info("Watch received queued command via transferUserInfo")
            WatchAppModel.shared.applyEnvelope(data)
        }
    }
}
