import Foundation

// MARK: - Route cache
//
// Every completed workout's `RouteLine`s, one JSON file per workout in Caches —
// device-local, outside SwiftData, built from `streamsData` (tens of ms per
// session) whenever a file is missing. A workout without a GPS track caches as
// an empty list.

nonisolated enum RouteCache {

    private static let directory = URL.cachesDirectory.appending(path: "routes")

    /// The lines of every completed workout since `since` (nil for all of them);
    /// drops the files of workouts no longer stored.
    @concurrent static func lines(since: Date?) async -> [RouteLine] {
        let items = await TrainingDataStore.shared.activityListItems()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cached = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        for orphan in cached.subtracting(items.map { file($0.id) }) { remove(orphan) }

        let ids = items.filter { item in since.map { item.start >= $0 } ?? true }.map(\.id)
        var lines = ids.filter { cached.contains(file($0)) }.flatMap { id in
            (try? JSONDecoder().decode([RouteLine].self, from: Data(contentsOf: directory.appending(path: file(id))))) ?? []
        }
        let missing = ids.filter { !cached.contains(file($0)) }
        for start in stride(from: 0, to: missing.count, by: 16) where !Task.isCancelled {
            let batch = await sources(Array(missing[start..<min(start + 16, missing.count)]))
            await withTaskGroup(of: (String, [RouteLine]).self) { group in
                for (id, legs) in batch {
                    group.addTask {
                        (id, legs.compactMap { RouteLine(family: $0.family, streams: WorkoutStreams.decode($0.streams) ?? [:]) })
                    }
                }
                for await (id, built) in group {
                    try? JSONEncoder().encode(built).write(to: directory.appending(path: file(id)), options: .atomic)
                    lines += built
                }
            }
        }
        return lines
    }

    /// Called wherever a workout's streams are rewritten, so its lines are rebuilt.
    static func invalidate(_ id: String) { remove(file(id)) }

    static func clear() { try? FileManager.default.removeItem(at: directory) }

    private static func remove(_ file: String) {
        try? FileManager.default.removeItem(at: directory.appending(path: file))
    }

    private static func file(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
    }

    /// Each workout's streams by sport: its own, or one per leg of a multisport
    /// session (transitions aside).
    @MainActor private static func sources(_ ids: [String]) -> [(id: String, legs: [(family: SportFamily, streams: Data)])] {
        ids.map { id in
            guard let record = TrainingDataStore.shared.activity(id: id) else { return (id, []) }
            let legs = record.segments
            guard legs.isEmpty else {
                return (id, legs.filter { !$0.isTransition }.map { ($0.family, $0.streamsData) })
            }
            return (id, [(SportFamily(sportKey: record.sport), record.streamsData)])
        }
    }
}
