import Foundation
import os

nonisolated public enum AppLog {
    private static let logger = Logger(subsystem: "com.openwatchagent", category: "OpenWatchAgent")

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        #if DEBUG
        print("[OpenWatch][INFO] \(message)")
        #endif
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        #if DEBUG
        print("[OpenWatch][ERROR] \(message)")
        #endif
    }
}
