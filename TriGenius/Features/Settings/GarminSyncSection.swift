import SwiftUI

/// How far back the Garmin history reaches: the first sync's window and the
/// history import's. Device-local, like the sync watermarks. A year by default —
/// the Statistics charts offer a 1Y range and `LTHREstimate` reads 365 days, so a
/// shorter history makes the estimates step for want of evidence.
enum GarminHistory: Int, CaseIterable, Identifiable {
    case threeMonths = 3, sixMonths = 6, oneYear = 12, twoYears = 24, fiveYears = 60

    static let key = "garmin_history_months"
    static var stored: GarminHistory {
        GarminHistory(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .oneYear
    }

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .threeMonths, .sixMonths: "\(rawValue) months"
        case .oneYear: "1 year"
        case .twoYears, .fiveYears: "\(rawValue / 12) years"
        }
    }
    var start: Date {
        let cal = Calendar.current
        return cal.date(byAdding: .month, value: -rawValue, to: cal.startOfDay(for: Date()))!
    }
}

/// Garmin's sync rows: the running sync's progress (the automatic ones included)
/// or the last sync, a manual sync, the history depth and its import, and a clean
/// slate.
struct GarminSyncSection: View {
    @AppStorage(GarminHistory.key) private var history: GarminHistory = .oneYear
    @State private var failed = false
    @State private var confirmDelete = false

    private var coordinator: DataSyncCoordinator { .shared }

    var body: some View {
        Group {
            status
            Button {
                run { await coordinator.sync(source: .garmin) }
            } label: {
                Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
            }
            Picker(selection: $history) {
                ForEach(GarminHistory.allCases) { Text($0.label).tag($0) }
            } label: {
                Label("History", systemImage: "calendar")
            }
            Button {
                run { await coordinator.syncGarmin(from: history.start) }
            } label: {
                Label("Import last \(history.label)", systemImage: "clock.arrow.circlepath")
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete Garmin data", systemImage: "trash")
                    .foregroundStyle(Theme.Palette.danger)
            }
            .alert("Delete Garmin data?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { coordinator.deleteGarminData() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes every Garmin activity and metric from TriGenius — including the max HR taken from your watch and your edits to those workouts. Your plans and the values you entered yourself stay. The next sync fetches the last \(history.label) again.")
            }
        }
        .disabled(coordinator.progress != nil)
    }

    @ViewBuilder private var status: some View {
        if let p = coordinator.progress, p.source == .garmin {
            if p.total > 0 {
                ProgressView(value: Double(p.done), total: Double(p.total)) {
                    Text("Activity \(p.done) of \(p.total)…")
                }
            } else {
                HStack { ProgressView(); Text("Syncing…") }
            }
        } else if failed {
            Label("Sync failed — check your Garmin connection.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        } else if let last = coordinator.lastSync(for: .garmin) {
            LabeledContent {
                Text(last, format: .relative(presentation: .named))
            } label: {
                Label("Last synced", systemImage: "clock")
            }
        }
    }

    private func run(_ sync: @escaping () async -> Int?) {
        failed = false
        Task { failed = await sync() == nil }
    }
}
