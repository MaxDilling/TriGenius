import Foundation
import WidgetKit

// MARK: - Weekly Target Snapshot Writer (app side)
//
// Boils the dashboard's already-computed per-discipline weekly targets +
// projections down into the shared `WeeklyTargetSnapshot` and hands it to the
// Home Screen widget. Called from the two places that already compute these:
// `DashboardViewModel.load(...)` (foreground) and `BackgroundCoordinator`'s
// proactive check (background) — so the widget stays fresh even when the app is
// only woken in the background.
//
// This lives in the app target (unlike the snapshot model itself) so it may
// reference the app-only `SportFamily` / `WeeklyTarget` / `WeeklyProjection`
// types and `SportFamily.icon`.

enum WeeklyTargetSnapshotWriter {

    /// Build a snapshot from the current targets/projections and persist it into
    /// the App Group, then ask WidgetKit to reload the timeline.
    static func write(
        targets: [SportFamily: WeeklyTarget],
        projections: [SportFamily: WeeklyProjection],
        weekStart: Date
    ) {
        let entries: [WeeklyTargetSnapshot.Entry] = SportFamily.triathlon.map { family in
            let target = targets[family] ?? WeeklyTarget(durationMinutes: 0, tss: 0)
            let projection = projections[family] ?? WeeklyProjection()
            return WeeklyTargetSnapshot.Entry(
                sport: family.rawValue,
                displayName: family.displayName,
                iconSystemName: family.icon,
                actualTSS: projection.actualTSS,
                targetTSS: target.tss,
                actualKm: projection.actualKm,
                targetKm: target.distanceKm,
                projectedTSS: projection.projectedTSS,
                projectedKm: projection.projectedKm
            )
        }

        let snapshot = WeeklyTargetSnapshot(
            generatedAt: Date(),
            weekStart: weekStart,
            disciplines: entries
        )
        snapshot.save()
        WidgetCenter.shared.reloadTimelines(ofKind: WeeklyTargetSnapshot.widgetKind)
    }
}
