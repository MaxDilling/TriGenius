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
// blacklist must survive a DB clear / schema reset (`deleteAllData`, the in-memory
// fallback), the very resets that re-sync everything; a SwiftData-backed list would
// be wiped by them and the ignored workout would return. It is an app preference,
// alongside the other UserDefaults settings.
//
// Cross-device sync rides `NSUbiquitousKeyValueStore` (iCloud KVS): UserDefaults is
// the local, offline-authoritative mirror every read hits; each write also lands in
// KVS, and `startSync()` pulls the cloud value back into the mirror on launch and on
// every external change. The whole list is one KVS key, so a merge is last-writer-
// wins — fine for a blacklist (a duplicate that reappears is simply re-hidden).

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
    private static let cloud = NSUbiquitousKeyValueStore.default

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

    /// Wipe the whole blacklist — part of the in-app full data erase.
    static func clearAll() {
        save([])
    }

    private static func save(_ list: [IgnoredWorkout]) {
        let data = try? JSONEncoder().encode(list)
        UserDefaults.standard.set(data, forKey: key)
        cloud.set(data, forKey: key)
        cloud.synchronize()
    }

    /// Pull the iCloud value into the local mirror and keep watching for changes
    /// pushed from other devices. Call once at launch.
    static func startSync() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud, queue: .main
        ) { _ in MainActor.assumeIsolated { mergeFromCloud() } }
        cloud.synchronize()
        mergeFromCloud()
    }

    /// Overwrite the local mirror with the cloud value (last-writer-wins) and nudge
    /// the readers — ingest re-reads `ids` on the next sync, the Settings list refreshes.
    private static func mergeFromCloud() {
        guard let data = cloud.data(forKey: key) else { return }
        UserDefaults.standard.set(data, forKey: key)
        NotificationCenter.default.post(name: .trainingDataDidChange, object: nil)
    }
}
