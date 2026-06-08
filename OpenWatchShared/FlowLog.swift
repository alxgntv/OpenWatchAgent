import Foundation

// ─── Ariadne's Thread [AT-0036] ─────────────────────
// What: Structured step logs for the Watch main-screen → voice → server flow.
// Why:  Terminal must show every step start/finish on both Watch and iPhone.
// Date: 2026-06-07
// Related: ContentView, WatchConnectivityWatchService, AppModel.handleWatchAudioFile
// ─────────────────────────────────────────────────────
public enum FlowLog {
    public enum Side: String {
        case watch = "WATCH"
        case iphone = "IPHONE"
    }

    public static func started(step: Int, side: Side, flow: String, detail: String = "") {
        let suffix = detail.isEmpty ? "" : " \(detail)"
        AppLog.info("[FLOW-\(step)][\(side.rawValue)] \(flow) started\(suffix)")
    }

    public static func function(step: Int, side: Side, flow: String, name: String) {
        AppLog.info("[FLOW-\(step)][\(side.rawValue)] \(flow) function=\(name)")
    }

    public static func progress(step: Int, side: Side, flow: String, detail: String) {
        AppLog.info("[FLOW-\(step)][\(side.rawValue)] \(flow) \(detail)")
    }

    public static func finished(step: Int, side: Side, flow: String, detail: String = "") {
        let suffix = detail.isEmpty ? "" : " \(detail)"
        AppLog.info("[FLOW-\(step)][\(side.rawValue)] \(flow) finished\(suffix)")
    }

    public static func result(step: Int, side: Side, flow: String, success: Bool, detail: String) {
        let status = success ? "success" : "failure"
        AppLog.info("[FLOW-\(step)][\(side.rawValue)] \(flow) \(status) \(detail)")
    }
}
