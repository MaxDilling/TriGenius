import Foundation

// MARK: - Ignored-workout blacklist
//
// A user-managed blacklist of completed-activity ids the athlete has chosen to
// hide — chiefly a duplicate session recorded on a second device (e.g. a generic
// Garmin "free workout" mirroring an Apple Watch run). `TrainingDataStore.ingest`
// skips any id in this set up-front, so an ignored activity never gets a
// `WorkoutRecord` row and is therefore absent from every surface (analytics/PMC,
// calendar, the coach) without per-read-site filtering.
//
// Persisted in UserDefaults — deliberately NOT in the SwiftData store: the
// blacklist must survive a DB clear / schema reset (`deleteAllData`, the
// in-memory fallback), the very resets that re-sync everything; a SwiftData-backed
// list would be wiped by them and the ignored workout would return. It is an app
// preference, alongside the other UserDefaults settings.

/// One blacklisted workout. Carries cached display metadata so the management UI
/// can list it without a (now-deleted) `WorkoutRecord`.
struct IgnoredWorkout: Codable, Identifiable {
    /// Stable stored id (`garmin:<id>`, `healthkit:<uuid>`), the ingest key.
    let id: String
    let name: String
    let date: Date
    let sport: String
    /// Origin ("garmin", "healthkit"), so a restore can re-sync the right source.
    let source: String
}

enum IgnoredWorkouts {
    private static let key = "ignored_workouts"

    /// All blacklisted entries, newest first.
    static var entries: [IgnoredWorkout] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([IgnoredWorkout].self, from: data) else { return [] }
        return list.sorted { $0.date > $1.date }
    }

    /// Fast membership set for the ingest skip.
    static var ids: Set<String> { Set(entries.map(\.id)) }

    /// Blacklist a workout (idempotent — replaces any existing entry with the same id).
    static func add(_ workout: IgnoredWorkout) {
        var list = entries.filter { $0.id != workout.id }
        list.append(workout)
        save(list)
    }

    /// Remove a workout from the blacklist so it can re-sync.
    static func remove(id: String) {
        save(entries.filter { $0.id != id })
    }

    private static func save(_ list: [IgnoredWorkout]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key)
    }
}
