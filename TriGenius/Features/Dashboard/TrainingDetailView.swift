import SwiftUI
import Charts
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Training Detail View
//
// Per-activity detail. Summary metrics (duration, distance, TSS, TE, avg HR,
// calories) come from the stored `ActivityRecord` / its `detailsJSON`. The HR
// time-series chart + CSV export are HealthKit-only for now (Garmin HR series
// is not yet stored — see plan's future "deeper Garmin history").

struct TrainingDetailView: View {
    let record: ActivityRecord

    @State private var heartRateSamples: [HeartRateSample] = []
    @State private var isLoadingHR = false
    @State private var exportFile: ExportFile?
    @State private var isExporting = false
    @State private var exportError: String?

    private var family: SportFamily { SportFamily(sportKey: record.sport) }
    private var details: [String: Any] {
        guard let data = record.detailsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }
    private var isHealthKit: Bool { record.source == "healthkit" }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: family.icon)
                        .font(.title)
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(family.color.gradient)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.name).font(.headline)
                        Text(record.date, style: .date)
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Metrics") {
                statRow("Duration", value: "\(Int(record.durationMinutes)) min", icon: "clock")
                if record.distanceKm > 0 {
                    statRow("Distance", value: String(format: "%.2f km", record.distanceKm), icon: "ruler")
                }
                statRow("TSS", value: record.tss.map { "\(Int($0.rounded()))" } ?? "—", icon: "gauge.with.dots.needle.67percent")
                if let te = record.aerobicTE {
                    statRow("Aerobic TE", value: String(format: "%.1f", te), icon: "lungs")
                }
                if let te = record.anaerobicTE {
                    statRow("Anaerobic TE", value: String(format: "%.1f", te), icon: "bolt.heart")
                }
                if let hr = details["avg_hr"] as? Int {
                    statRow("Avg HR", value: "\(hr) bpm", icon: "heart")
                }
                if let kcal = details["calories"] as? Int {
                    statRow("Calories", value: "\(kcal) kcal", icon: "flame")
                }
            }

            if isHealthKit {
                heartRateSection
            }
        }
        .navigationTitle(family.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await loadHeartRate() }
        .sheet(item: $exportFile) { file in ShareSheet(items: [file.url]) }
        .alert("Export failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    @ViewBuilder
    private var heartRateSection: some View {
        Section("Heart rate") {
            if isLoadingHR {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if heartRateSamples.isEmpty {
                Text("No heart-rate samples available.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Chart(heartRateSamples) { sample in
                    LineMark(x: .value("Time", sample.date), y: .value("BPM", sample.bpm))
                        .foregroundStyle(Color.red.gradient)
                        .interpolationMethod(.linear)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxisLabel("BPM")
                .frame(height: 180)

                Button(action: exportCSV) {
                    if isExporting {
                        ProgressView()
                    } else {
                        Label("Export heart rate (CSV)", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isExporting)
            }
        }
    }

    private func statRow(_ label: String, value: String, icon: String) -> some View {
        HStack {
            Label(label, systemImage: icon)
            Spacer()
            Text(value).foregroundStyle(.secondary).fontWeight(.medium)
        }
    }

    // The HealthKit workout UUID, stripped of the source prefix.
    private var healthKitWorkoutID: String {
        if let raw = details["id"] as? String { return raw }
        return record.id.replacingOccurrences(of: "healthkit:", with: "")
    }

    private func loadHeartRate() async {
        guard isHealthKit, heartRateSamples.isEmpty, !isLoadingHR else { return }
        isLoadingHR = true
        defer { isLoadingHR = false }
        if let workout = try? await HealthKitService.shared.fetchWorkout(id: healthKitWorkoutID),
           let samples = try? await HealthKitService.shared.fetchHeartRateSamples(during: workout) {
            heartRateSamples = samples
        }
    }

    private func exportCSV() {
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let csv = try await HealthKitService.shared.heartRateCSV(forWorkoutID: healthKitWorkoutID)
                let safeSport = family.displayName
                let filename = "HR_\(safeSport)_\(Int(record.date.timeIntervalSince1970)).csv"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                try csv.write(to: url, atomically: true, encoding: .utf8)
                exportFile = ExportFile(url: url)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}

// MARK: - CSV Export Helpers
//
// Used by the training detail view's heart-rate export.

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
