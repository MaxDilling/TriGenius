import SwiftUI

// MARK: - Ignored workouts management
//
// Lists the athlete's blacklisted workouts (see `IgnoredWorkouts`) and lets them
// restore one. Restoring removes it from the blacklist and re-syncs its source
// from scratch — an incremental sync won't re-fetch past its watermark, so the
// full `resync` is what brings the row back.

struct IgnoredWorkoutsView: View {
    @State private var entries = IgnoredWorkouts.entries
    @State private var restoring: String?

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No ignored workouts",
                    systemImage: "eye.slash",
                    description: Text("Ignore a duplicate from its detail view to hide it from your calendar and analytics.")
                )
            } else {
                Section {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                } footer: {
                    Text("Ignored workouts never re-sync. Restoring one re-fetches its source.")
                }
            }
        }
        .navigationTitle("Ignored Workouts")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func row(_ entry: IgnoredWorkout) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.body)
                HStack(spacing: 4) {
                    Text(entry.date, style: .date)
                    Text("·")
                    Text(entry.source.capitalized)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if restoring == entry.id {
                ProgressView()
            } else {
                Button("Restore") { restore(entry) }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func restore(_ entry: IgnoredWorkout) {
        guard let source = Self.dataSource(for: entry.source) else {
            // Unknown origin — just un-blacklist; no source to re-pull from.
            TrainingDataStore.shared.restoreIgnoredWorkout(id: entry.id)
            entries = IgnoredWorkouts.entries
            return
        }
        restoring = entry.id
        TrainingDataStore.shared.restoreIgnoredWorkout(id: entry.id)
        Task {
            _ = await DataSyncCoordinator.shared.resync(source: source)
            restoring = nil
            entries = IgnoredWorkouts.entries
        }
    }

    /// Map a stored `source` string ("garmin"/"healthkit") to its read source.
    private static func dataSource(for source: String) -> DataSource? {
        switch source {
        case "garmin": return .garmin
        case "healthkit": return .appleHealth
        default: return nil
        }
    }
}
