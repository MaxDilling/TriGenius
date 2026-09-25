import Foundation
import WidgetKit

// MARK: - Weekly Target Snapshot Writer (app side)
//
// Boils this week's rings (`WeeklyTargets.thisWeek`) down into the shared
// `WeeklyTargetSnapshot` and hands it to the Home Screen widget. Called from
// `DashboardViewModel.load(...)` (foreground) and `BackgroundCoordinator`'s
// proactive check (background) — so the widget stays fresh even when the app is
// only woken in the background.
//
// This lives in the app target (unlike the snapshot model itself) so it may
// reference the app-only `SportFamily` / `WeeklyTarget` / `WeeklyProjection`
// types and `SportFamily.icon`.

enum WeeklyTargetSnapshotWriter {

    /// Persist a snapshot into the App Group, then ask WidgetKit to reload the
    /// timeline. One entry per visible family — the widget only draws a ring per
    /// entry, so this gates both widget sizes.
    static func write(_ week: WeekTargets) {
        let entries: [WeeklyTargetSnapshot.Entry] = week.visibleFamilies.map { family in
            let target = week.target(for: family)
            let projection = week.projection(for: family)
            return WeeklyTargetSnapshot.Entry(
                sport: family.rawValue,
                displayName: family.displayName,
                iconSystemName: family.icon,
                actualTSS: projection.actualTSS,
                targetTSS: target.tss,
                actualKm: projection.actualKm,
                targetKm: target.distanceKm,
                projectedTSS: projection.projectedTSS,
                projectedKm: projection.projectedKm,
                creditedTSS: projection.creditedTSS,
                projectedCreditTSS: projection.projectedCreditTSS
            )
        }

        let snapshot = WeeklyTargetSnapshot(
            generatedAt: Date(),
            weekStart: week.weekStart,
            disciplines: entries
        )
        snapshot.save()
        WidgetCenter.shared.reloadTimelines(ofKind: WeeklyTargetSnapshot.widgetKind)
    }
}
