import Foundation

nonisolated public enum WatchConnectivityCodec {
    public static let payloadKey = "owPayload"

    /// Metadata keys used when transferring a recorded voice file from the Watch to the iPhone.
    public static let audioKindKey = "owAudio"
    public static let audioJobIdKey = "owAudioJobId"

    public static func userInfo(from envelope: WatchEnvelope) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(envelope) else { return nil }
        return [payloadKey: data]
    }

    public static func payloadData(from userInfo: [String: Any]) -> Data? {
        if let data = userInfo[payloadKey] as? Data { return data }
        if let data = userInfo["payload"] as? Data { return data }
        return nil
    }

    public static func applicationContext(from envelope: WatchEnvelope) -> [String: Any]? {
        userInfo(from: envelope)
    }
}
