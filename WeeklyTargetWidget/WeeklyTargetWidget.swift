import SwiftUI
import WidgetKit

// MARK: - Weekly Target Widget
//
// A read-only Home Screen widget that mirrors the dashboard's weekly volume
// rings. It reads the snapshot the app writes into the shared App Group
// (`WeeklyTargetSnapshot`) — it links no SwiftData / analytics / CoachMemory.
// The app push-reloads the timeline whenever the numbers change
// (`WeeklyTargetSnapshotWriter`); the hourly policy is just a safety net.

struct WeeklyTargetEntry: TimelineEntry {
    let date: Date
    let snapshot: WeeklyTargetSnapshot
}

struct WeeklyTargetProvider: TimelineProvider {
    func placeholder(in context: Context) -> WeeklyTargetEntry {
        WeeklyTargetEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (WeeklyTargetEntry) -> Void) {
        let snapshot = context.isPreview ? .placeholder : (WeeklyTargetSnapshot.load() ?? .placeholder)
        completion(WeeklyTargetEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WeeklyTargetEntry>) -> Void) {
        let snapshot = WeeklyTargetSnapshot.load() ?? .placeholder
        let entry = WeeklyTargetEntry(date: Date(), snapshot: snapshot)
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct WeeklyTargetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WeeklyTargetSnapshot.widgetKind, provider: WeeklyTargetProvider()) { entry in
            WeeklyTargetWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Weekly Target")
        .description("Your swim / bike / run volume progress for this week.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview(as: .systemMedium) {
    WeeklyTargetWidget()
} timeline: {
    WeeklyTargetEntry(date: Date(), snapshot: .placeholder)
}
