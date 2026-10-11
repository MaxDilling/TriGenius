import SwiftUI

// MARK: - Ignored workouts management
//
// Lists the athlete's blacklisted workouts (see `IgnoredWorkouts`) and lets them
// restore one. Restoring removes it from the blacklist and re-fetches it — an
// incremental sync won't reach back past its watermark: Garmin syncs from the
// workout's day, Apple Health re-reads every workout.

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
        guard let source = DataSource(storedSource: entry.source) else {
            // Unknown origin — just un-blacklist; no source to re-pull from.
            TrainingDataStore.shared.restoreIgnoredWorkout(id: entry.id)
            entries = IgnoredWorkouts.entries
            return
        }
        restoring = entry.id
        TrainingDataStore.shared.restoreIgnoredWorkout(id: entry.id)
        Task {
            switch source {
            case .garmin: await DataSyncCoordinator.shared.syncGarmin(from: entry.date)
            case .appleHealth: await DataSyncCoordinator.shared.resyncAppleHealth()
            }
            restoring = nil
            entries = IgnoredWorkouts.entries
        }
    }
}
