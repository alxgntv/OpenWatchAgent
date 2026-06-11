import WidgetKit
import SwiftUI

// ─── Ariadne's Thread [AT-0132] ─────────────────────
// What: WidgetKit watch complications for OpenWatch (watch face + Smart Stack).
// Why:  ClockKit replaced by WidgetKit on watchOS 9+; one extension serves all complication families.
// Date: 2026-06-10
// Related: Apple doc Migrating ClockKit complications to WidgetKit
// ─────────────────────────────────────────────────────

struct ComplicationEntry: TimelineEntry {
    let date: Date
    let hasActiveJob: Bool
}

struct ComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> ComplicationEntry {
        ComplicationEntry(date: Date(), hasActiveJob: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> Void) {
        completion(ComplicationEntry(date: Date(), hasActiveJob: false))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        let now = Date()
        let hasActiveJob = ComplicationActiveJobState.hasActiveJob
        let entry = ComplicationEntry(date: now, hasActiveJob: hasActiveJob)
        let refresh: Date
        if hasActiveJob {
            refresh = Calendar.current.date(byAdding: .minute, value: 1, to: now) ?? now.addingTimeInterval(60)
        } else {
            refresh = Calendar.current.date(byAdding: .hour, value: 6, to: now) ?? now.addingTimeInterval(6 * 3600)
        }
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }
}

// ─── Ariadne's Thread [AT-0167] ─────────────────────
// What: Icon-only complication using a vector SVG asset (full color where supported, accent silhouette otherwise).
// Why:  accessoryRectangular supports fullColor; accessoryCircular/corner are accented/vibrant only and tint the silhouette.
// Date: 2026-06-11
// Related: ComplicationAgent.imageset openclaw-dark.svg, Apple doc Preparing widgets for additional contexts and appearances
// ─────────────────────────────────────────────────────
private struct ComplicationAgentGlyph: View {
    var body: some View {
        Image("ComplicationAgent")
            .resizable()
            .scaledToFit()
            .widgetAccentable()
            .unredacted()
    }
}

struct OpenWatchComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ComplicationProvider.Entry

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("OpenWatch").unredacted()
        case .accessoryCorner:
            ComplicationAgentGlyph()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            ComplicationAgentGlyph()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(2)
        }
    }
}

struct OpenWatchComplication: Widget {
    let kind = "OpenWatchComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ComplicationProvider()) { entry in
            OpenWatchComplicationView(entry: entry)
                .containerBackground(for: .widget) {
                    AccessoryWidgetBackground()
                }
        }
        .configurationDisplayName("OpenWatch")
        .description("Open OpenWatch from your watch face.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCorner,
        ])
    }
}

@main
struct OpenWatchComplicationBundle: WidgetBundle {
    var body: some Widget {
        OpenWatchComplication()
    }
}
