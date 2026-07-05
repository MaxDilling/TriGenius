import SwiftUI

/// Settings sub-page for the read sources (Garmin / Apple Health, read in parallel
/// and merged into the local store) and the single write target. Split out of the
/// root Settings list so that screen stays scannable.
struct DataSourcesView: View {
    @ObservedObject var settings: AppSettings
    let onBackendChanged: () -> Void

    var body: some View {
        List {
            // Read sources — parallel; merged into the local store. Source selection
            // only; each enabled source's own controls live in its section below.
            Section {
                ForEach(DataSource.allCases) { source in
                    Toggle(isOn: readBinding(source)) {
                        Label(source.displayName, systemImage: source.icon)
                    }
                }
                // When both providers feed activities, pick exactly one to supply the
                // performance + wellness metrics, so FTP/VO₂max/sleep aren't sourced twice.
                if settings.readSources.count > 1 {
                    Picker("Metrics from", selection: $settings.metricsSource) {
                        ForEach(settings.readSources.sorted(by: { $0.rawValue < $1.rawValue })) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                }
            } header: {
                Text("Read From")
            } footer: {
                Text("Pull training and health data from one or both. Garmin Connect workouts already mirrored into Apple Health are skipped to avoid duplicates. When both are on, performance and wellness metrics come from the single \u{201C}Metrics from\u{201D} provider.")
            }

            // Per-source controls — one section each, headed by the provider, so it's
            // clear what belongs to whom. Each carries a Re-sync that re-pulls and
            // recomputes that source's history in place.
            if settings.readSources.contains(.appleHealth) {
                Section {
                    ReadSourceSyncSection(source: .appleHealth)
                } header: {
                    Label(DataSource.appleHealth.displayName, systemImage: DataSource.appleHealth.icon)
                } footer: {
                    Text("Re-sync re-reads every Apple Health workout — recomputing heart rate zones and TSS.")
                }
            }
            if settings.readSources.contains(.garmin) {
                Section {
                    GarminLoginSection(settings: settings)
                    ReadSourceSyncSection(source: .garmin)
                } header: {
                    Label(DataSource.garmin.displayName, systemImage: DataSource.garmin.icon)
                } footer: {
                    Text("Re-sync re-fetches your Garmin history and recomputes TSS for every activity.")
                }
            }

            // Write target — where the coach schedules planned workouts.
            Section {
                Picker("Schedule workouts to", selection: $settings.writeTarget) {
                    ForEach(WriteTarget.allCases.filter { $0.isSupportedOnThisPlatform }) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                .onChange(of: settings.writeTarget) { onBackendChanged() }

                if settings.writeTarget == .garmin, !settings.readSources.contains(.garmin) {
                    GarminLoginSection(settings: settings)
                }
            } header: {
                Text("Write To")
            } footer: {
                Text(settings.writeTarget == .appleWatch
                     ? "Planned workouts are sent to the Apple Watch via WorkoutKit — start them from the Workout app."
                     : "Planned workouts are created and scheduled in Garmin Connect. Switching targets re-syncs upcoming plans; nothing is lost.")
            }
        }
        .navigationTitle("Data Sources")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Toggle binding for a read source. Keeps at least one source enabled.
    private func readBinding(_ source: DataSource) -> Binding<Bool> {
        Binding(
            get: { settings.readSources.contains(source) },
            set: { on in
                var next = settings.readSources
                if on { next.insert(source) } else { next.remove(source) }
                if next.isEmpty { next = [source] } // never leave zero sources
                settings.readSources = next
                onBackendChanged()
            }
        )
    }
}
