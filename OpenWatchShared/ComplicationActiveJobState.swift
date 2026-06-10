import Foundation

// ─── Ariadne's Thread [AT-0139] ─────────────────────
// What: App Group flag so the watch-face complication can show a loader while jobs are executing.
// Why:  Complication runs in a separate process and must read live job state from the Watch app.
// Date: 2026-06-10
// Related: [AT-0132] OpenWatchComplication/OpenWatchComplication, [AT-0049] WatchAppModel.upsert
// ─────────────────────────────────────────────────────

enum ComplicationActiveJobState {
    static let appGroupID = "group.com.alexeyignatov.OpenWatch"
    static let hasActiveJobKey = "complicationHasActiveJob"
    static let widgetKind = "OpenWatchComplication"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func setHasActiveJob(_ value: Bool) {
        guard let defaults else {
            AppLog.error("ComplicationActiveJobState App Group unavailable group=\(appGroupID)")
            return
        }
        let previous = defaults.bool(forKey: hasActiveJobKey)
        guard previous != value else { return }
        defaults.set(value, forKey: hasActiveJobKey)
        AppLog.info("ComplicationActiveJobState hasActiveJob=\(value)")
    }

    static var hasActiveJob: Bool {
        defaults?.bool(forKey: hasActiveJobKey) ?? false
    }
}
