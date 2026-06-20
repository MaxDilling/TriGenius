import SwiftUI
import HealthKit
import Charts
import SwiftData
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - App Root

@main
struct TriGeniusApp: App {
    @StateObject private var memory = CoachMemory()
    @StateObject private var settings = AppSettings()
    @State private var brain: CoachBrain?
    @State private var launchStatus = "Initialisiere…"

    var body: some Scene {
        WindowGroup {
            if let brain {
                RootTabView(brain: brain, memory: memory, settings: settings) {
                    applyBackend(to: brain)
                }
            } else {
                ProgressView(launchStatus)
                    .task { await setupBrain() }
            }
        }
        .modelContainer(TrainingDataStore.shared.container)
    }

    private func setupBrain() async {
        let b = CoachBrain(memory: memory, dataSource: settings.dataSource)
        applyBackend(to: b)
        // GOAL.md step 2: sync the latest activities into the local database
        // before revealing the UI, so the coach reads 100% fresh data.
        launchStatus = "Synchronisiere Aktivitäten…"
        await DataSyncCoordinator.shared.sync(source: settings.dataSource)
        brain = b
    }

    private func applyBackend(to brain: CoachBrain) {
        brain.setDataSource(settings.dataSource)
        brain.setBackend(settings.makeBackend())
    }
}

// MARK: - Root Tab View

struct RootTabView: View {
    let brain: CoachBrain
    @ObservedObject var memory: CoachMemory
    @ObservedObject var settings: AppSettings
    let onBackendChanged: () -> Void

    var body: some View {
        TabView {
            NavigationStack {
                CoachChatView(brain: brain)
            }
            .tabItem {
                Label("Coach", systemImage: "bubble.left.and.bubble.right.fill")
            }

            NavigationStack {
                HealthDashboardView()
            }
            .tabItem {
                Label("Health", systemImage: "heart.fill")
            }

            NavigationStack {
                SettingsView(
                    settings: settings,
                    memory: memory,
                    onBackendChanged: onBackendChanged
                )
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
        }
    }
}

// MARK: - Health Dashboard

struct HealthDashboardView: View {
    @State private var viewModel = HealthDashboardViewModel()

    var body: some View {
        List {
            if viewModel.isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading health data…")
                        Spacer()
                    }
                    .padding()
                }
            } else if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            } else {
                // Metrics section
                if let metrics = viewModel.metrics {
                    Section("Health metrics (last 7 days)") {
                        metricRow("Steps (daily avg)", value: "\(Int(metrics.dailySteps))", icon: "figure.walk", color: .green)
                        if let hr = metrics.averageHRbpm {
                            metricRow("Heart rate (avg)", value: "\(Int(hr)) bpm", icon: "heart", color: .red)
                        }
                        if let hrv = metrics.latestHRVms {
                            metricRow("HRV (latest)", value: "\(Int(hrv)) ms", icon: "waveform.path.ecg", color: .blue)
                        }
                        metricRow("Sleep (daily avg)", value: String(format: "%.1f h", metrics.avgSleepHours), icon: "moon.fill", color: .indigo)
                        metricRow("Active energy (daily avg)", value: "\(Int(metrics.avgActiveEnergyKcal)) kcal", icon: "flame.fill", color: .orange)
                    }
                }

                // Recent workouts section
                if !viewModel.workouts.isEmpty {
                    Section("Recent workouts") {
                        ForEach(viewModel.workouts, id: \.id) { workout in
                            WorkoutRow(workout: workout)
                        }
                    }
                }

                // HR Chart
                if !viewModel.heartRateSamples.isEmpty {
                    Section("Heart rate – last workout") {
                        Chart(viewModel.heartRateSamples) { sample in
                            LineMark(
                                x: .value("Time", sample.date),
                                y: .value("BPM", sample.bpm)
                            )
                            .foregroundStyle(Color.red.gradient)
                            .interpolationMethod(.linear)
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .chartYAxisLabel("BPM")
                        .frame(height: 180)
                    }
                }
            }
        }
        .navigationTitle("Health")
        .refreshable { await viewModel.loadData() }
        .task {
            // Only load once automatically; avoids re-running HealthKit
            // authorization + queries on every tab switch (perceived hang).
            await viewModel.loadInitialIfNeeded()
        }
    }

    private func metricRow(_ label: String, value: String, icon: String, color: Color) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .foregroundStyle(color)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Workout Row

struct WorkoutRow: View {
    let workout: WorkoutSummary

    @State private var exportFile: ExportFile?
    @State private var isExporting = false
    @State private var exportError: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: sportIcon)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(sportColor.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(workout.sport)
                    .font(.headline)
                Text(workout.date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(workout.durationMin)) min")
                    .font(.subheadline)
                    .fontWeight(.medium)
                if let km = workout.distanceKm {
                    Text(String(format: "%.1f km", km))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: exportCSV) {
                if isExporting {
                    ProgressView()
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body)
                        .frame(width: 28, height: 28)
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.blue)
            .disabled(isExporting)
            .accessibilityLabel("Export heart rate as CSV")
        }
        .padding(.vertical, 4)
        .sheet(item: $exportFile) { file in
            ShareSheet(items: [file.url])
        }
        .alert("Export failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private func exportCSV() {
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let csv = try await HealthKitService.shared.heartRateCSV(forWorkoutID: workout.id)
                let safeSport = workout.sport.replacingOccurrences(of: " ", with: "_")
                let filename = "HR_\(safeSport)_\(workout.date).csv"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                try csv.write(to: url, atomically: true, encoding: .utf8)
                exportFile = ExportFile(url: url)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private var sportIcon: String {
        switch workout.sport {
        case "Running": return "figure.run"
        case "Cycling": return "figure.outdoor.cycle"
        case "Swimming": return "figure.pool.swim"
        case "Triathlon": return "figure.triathlon"
        case "Strength": return "dumbbell"
        default: return "figure.mixed.cardio"
        }
    }

    private var sportColor: Color {
        switch workout.sport {
        case "Running": return .orange
        case "Cycling": return .blue
        case "Swimming": return .cyan
        case "Triathlon": return .purple
        case "Strength": return .gray
        default: return .green
        }
    }
}

// MARK: - CSV Export Helpers

/// Wraps an exported file URL so it can drive a `.sheet(item:)` presentation.
struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Bridges the platform-native share UI into SwiftUI for the system share sheet.
#if canImport(UIKit)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#elseif canImport(AppKit)
struct ShareSheet: NSViewRepresentable {
    let items: [Any]

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard view.window != nil else { return }
            let picker = NSSharingServicePicker(items: items)
            picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif

// MARK: - Health Dashboard ViewModel

@MainActor
@Observable
final class HealthDashboardViewModel {
    var metrics: HealthMetricsSummary?
    var workouts: [WorkoutSummary] = []
    var heartRateSamples: [HeartRateSample] = []
    var isLoading = false
    var errorMessage: String?
    private var hasLoaded = false

    func loadInitialIfNeeded() async {
        guard !hasLoaded else { return }
        await loadData()
    }

    func loadData() async {
        isLoading = true
        errorMessage = nil

        do {
            try await HealthKitService.shared.requestAuthorization()
            async let metricsTask = HealthKitService.shared.fetchHealthMetrics(days: 7)
            async let workoutsTask = HealthKitService.shared.fetchRecentWorkouts(count: 8)
            let (m, w) = try await (metricsTask, workoutsTask)
            metrics = m
            workouts = w

            // Fetch HR for most recent workout
            if !workouts.isEmpty {
                // We need the HKWorkout object — refetch it
                let hrSamples = try? await fetchHRForFirstWorkout()
                heartRateSamples = hrSamples ?? []
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        hasLoaded = true
        isLoading = false
    }

    private func fetchHRForFirstWorkout() async throws -> [HeartRateSample] {
        // Fetch first workout as HKWorkout to get HR data
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                guard let workout = samples?.first as? HKWorkout else {
                    continuation.resume(returning: [])
                    return
                }
                Task {
                    let samples = (try? await HealthKitService.shared.fetchHeartRateSamples(during: workout)) ?? []
                    continuation.resume(returning: samples)
                }
            }
            HKHealthStore().execute(query)
        }
    }
}
