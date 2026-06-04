import Combine
import Foundation
import WatchConnectivity

@MainActor
final class WatchConnectivityPhoneService: NSObject, ObservableObject {
    static let shared = WatchConnectivityPhoneService()

    private let session = WCSession.default

    override private init() {
        super.init()
        if WCSession.isSupported() {
            session.delegate = self
            session.activate()
            AppLog.info("Activating WCSession on iPhone")
        }
    }

    func publish(pairing: PairingSnapshot, jobs: [VoiceJob], ttsEnabled: Bool, ttsLanguage: String) {
        guard session.activationState == .activated else { return }
        let envelope = WatchEnvelope(kind: .jobsSnapshot, pairing: pairing, jobs: jobs, ttsEnabled: ttsEnabled, ttsLanguage: ttsLanguage)
        pushToWatch(envelope, preferImmediate: true)
    }

    func publish(job: VoiceJob) {
        guard session.activationState == .activated else { return }
        let envelope = WatchEnvelope(kind: .jobUpdated, job: job)
        pushToWatch(envelope, preferImmediate: true)
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

    private func pushToWatch(_ envelope: WatchEnvelope, preferImmediate: Bool) {
        guard let context = WatchConnectivityCodec.applicationContext(from: envelope) else { return }
        do {
            try session.updateApplicationContext(context)
            AppLog.info("Pushed application context to Watch kind=\(envelope.kind.rawValue)")
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
