import AppIntents
import Foundation

// ─── Ariadne's Thread [AT-0131] ─────────────────────
// What: AppIntent that opens the OpenWatch watch app from the Smart Stack widget / Double Tap.
// Why:  watchOS 11+ Double Tap primary action on a widget Button must run a registered AppIntent in the host app process.
// Date: 2026-06-10
// Related: [AT-0132] OpenWatchComplication interactive widget, Apple doc enabling-double-tap
// ─────────────────────────────────────────────────────
struct OpenWatchLaunchIntent: AppIntent {
    static var title: LocalizedStringResource = "Open OpenWatch"
    static var description = IntentDescription("Opens OpenWatch from the Smart Stack or watch face.")
    static var openAppWhenRun: Bool { true }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}
