import Foundation

// MARK: - Weekly Target Snapshot
//
// The tiny data contract between the app and the Home Screen widget. The app
// already computes per-discipline weekly targets/projections for the dashboard
// (`WeeklyTargets.targets` / `.projection`); rather than share the whole
// SwiftData store + coach_memory.json with the widget extension, it boils those
// down to this Codable snapshot and writes it into the shared App Group
// container. The widget only ever reads this — it links no analytics, no
// SwiftData, no CoachMemory.
//
// Pure Foundation on purpose: this file is compiled into BOTH the app and the
// widget extension, so it must not depend on app-only types (SportFamily,
// WeeklyTarget, …). The per-sport identity it needs (raw key, display name, SF
// Symbol) is carried inline in each `Entry`.

struct WeeklyTargetSnapshot: Codable {
    /// One triathlon discipline's week: completed (actual), the weekly goal
    /// (target), and the expected close given what's still planned (projected).
    /// Mirrors the dashboard's `VolumeRing` inputs.
    struct Entry: Codable {
        /// `SportFamily` raw value ("swim" / "bike" / "run") — the widget maps
        /// this to its accent color locally.
        var sport: String
        var displayName: String
        var iconSystemName: String
        var actualTSS: Double
        var targetTSS: Double
        var actualKm: Double
        var targetKm: Double
        var projectedTSS: Double
        var projectedKm: Double
    }

    var generatedAt: Date
    /// Monday of the week these numbers describe (for the widget's header).
    var weekStart: Date
    var disciplines: [Entry]

    // MARK: App Group I/O

    /// Shared container both the app and the widget can reach.
    static let appGroupID = "group.net.Narica.TriGenius"
    static let fileName = "weekly_target_snapshot.json"
    /// Widget timeline kind — kept here so writer and widget agree on one string.
    static let widgetKind = "WeeklyTargetWidget"

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(fileName)
    }

    /// Read the latest snapshot the app wrote. `nil` when none exists yet or the
    /// App Group is unavailable (the widget falls back to `.placeholder`).
    static func load() -> WeeklyTargetSnapshot? {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WeeklyTargetSnapshot.self, from: data)
    }

    /// Persist into the App Group container (app side).
    func save() {
        guard let url = Self.fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Placeholder

    /// Sample data for the widget gallery / before the app has written anything.
    static var placeholder: WeeklyTargetSnapshot {
        WeeklyTargetSnapshot(
            generatedAt: Date(),
            weekStart: Date(),
            disciplines: [
                Entry(sport: "swim", displayName: "Swim", iconSystemName: "figure.pool.swim",
                      actualTSS: 60, targetTSS: 120, actualKm: 4, targetKm: 8,
                      projectedTSS: 110, projectedKm: 7),
                Entry(sport: "bike", displayName: "Bike", iconSystemName: "figure.outdoor.cycle",
                      actualTSS: 180, targetTSS: 300, actualKm: 70, targetKm: 120,
                      projectedTSS: 300, projectedKm: 120),
                Entry(sport: "run", displayName: "Run", iconSystemName: "figure.run",
                      actualTSS: 90, targetTSS: 210, actualKm: 14, targetKm: 32,
                      projectedTSS: 170, projectedKm: 26),
            ]
        )
    }
}
