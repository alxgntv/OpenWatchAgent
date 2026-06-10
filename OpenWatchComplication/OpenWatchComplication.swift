import AppIntents
import WidgetKit
import SwiftUI

// ─── Ariadne's Thread [AT-0132] ─────────────────────
// What: Interactive Smart Stack / watch-face widget with Double Tap primary action to open OpenWatch.
// Why:  User wants Double Tap from watch face when OpenWatch widget is in Smart Stack (watchOS 11+ handGestureShortcut).
// Date: 2026-06-10
// Related: [AT-0131] OpenWatchShared/OpenWatchLaunchIntent, Apple doc enabling-double-tap
// ─────────────────────────────────────────────────────

/// A single timeline entry. Carries whether a job is executing so the glyph can switch mic ↔ loader.
struct ComplicationEntry: TimelineEntry {
    let date: Date
    let hasActiveJob: Bool
}

/// Provides timeline entries for the complication. Refreshes faster while jobs are executing.
struct ComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> ComplicationEntry {
        ComplicationEntry(date: Date(), hasActiveJob: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> Void) {
        completion(ComplicationEntry(date: Date(), hasActiveJob: ComplicationActiveJobState.hasActiveJob))
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
        let timeline = Timeline(entries: [entry], policy: .after(refresh))
        completion(timeline)
    }
}

private struct DoubleTapPrimaryActionModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content.handGestureShortcut(.primaryAction)
        } else {
            content
        }
    }
}

private extension View {
    func openWatchDoubleTapPrimaryAction() -> some View {
        modifier(DoubleTapPrimaryActionModifier())
    }
}

/// Renders the complication for each supported accessory family.
struct OpenWatchComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ComplicationProvider.Entry

    var body: some View {
        Button(intent: OpenWatchLaunchIntent()) {
            widgetContent
        }
        .buttonStyle(.plain)
        .openWatchDoubleTapPrimaryAction()
    }

    // ─── Ariadne's Thread [AT-0139] ─────────────────────
    // What: Show ProgressView on the watch face while jobs are executing; mic when idle.
    // Why:  User wants the complication to reflect in-flight work the same way as the chat Speak button.
    // Date: 2026-06-10
    // Related: [AT-0139] shared→ComplicationActiveJobState, WatchAppModel.syncComplicationActiveJobState
    // ─────────────────────────────────────────────────────
    @ViewBuilder
    private var statusGlyph: some View {
        if entry.hasActiveJob {
            ProgressView()
        } else {
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .semibold))
        }
    }

    @ViewBuilder
    private var widgetContent: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                statusGlyph
            }
        case .accessoryCorner:
            if entry.hasActiveJob {
                ProgressView()
                    .widgetLabel("Working")
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .widgetLabel("OpenWatch")
            }
        case .accessoryInline:
            if entry.hasActiveJob {
                HStack(spacing: 4) {
                    ProgressView()
                    Text("OpenWatch")
                }
            } else {
                Label("OpenWatch", systemImage: "mic.fill")
            }
        case .accessoryRectangular:
            HStack(spacing: 6) {
                if entry.hasActiveJob {
                    ProgressView()
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("OpenWatch")
                        .font(.headline)
                    Text(entry.hasActiveJob ? "Working…" : "Double Tap to open")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            statusGlyph
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
        .description("Open OpenWatch from Smart Stack. Double Tap when this widget is on your watch face.")
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
