import WidgetKit
import SwiftUI

// Ariadne's Thread
// What: WidgetKit complication for the OpenWatch watch app. Renders accessory families on the watch face
//       and acts as a quick-launch entry point into the app (tapping any accessory widget opens the host app).
// Why:  The user wants OpenWatch reachable directly from the watch face. WidgetKit (not deprecated ClockKit)
//       is the supported path on watchOS 10+.
// When: 2026-06-04
// Notes: Static configuration (no shared data yet). Live data (e.g. usage) would require an App Group to read
//        values written by the watch app; that is intentionally out of scope here to keep this self-contained.

/// A single timeline entry. The complication is static branding, so the entry only carries a timestamp.
struct ComplicationEntry: TimelineEntry {
    let date: Date
}

/// Provides timeline entries for the complication. Static content with a periodic refresh so the system keeps it warm.
struct ComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> ComplicationEntry {
        ComplicationEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> Void) {
        completion(ComplicationEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        let now = Date()
        let next = Calendar.current.date(byAdding: .hour, value: 6, to: now) ?? now.addingTimeInterval(6 * 3600)
        let timeline = Timeline(entries: [ComplicationEntry(date: now)], policy: .after(next))
        completion(timeline)
    }
}

/// Renders the complication for each supported accessory family.
struct OpenWatchComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ComplicationProvider.Entry

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
            }
        case .accessoryCorner:
            Image(systemName: "mic.fill")
                .font(.system(size: 18, weight: .semibold))
                .widgetLabel("OpenWatch")
        case .accessoryInline:
            Label("OpenWatch", systemImage: "mic.fill")
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 18, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("OpenWatch")
                        .font(.headline)
                    Text("Tap to talk")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            Image(systemName: "mic.fill")
        }
    }
}

/// The complication widget definition. `StaticConfiguration` because there are no user-configurable parameters.
struct OpenWatchComplication: Widget {
    let kind = "OpenWatchComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ComplicationProvider()) { entry in
            OpenWatchComplicationView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("OpenWatch")
        .description("Quick-launch OpenWatch from your watch face.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCorner,
        ])
    }
}

/// The widget bundle entry point for the extension.
@main
struct OpenWatchComplicationBundle: WidgetBundle {
    var body: some Widget {
        OpenWatchComplication()
    }
}
