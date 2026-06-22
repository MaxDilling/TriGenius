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
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                header
                heroCapsule
                coachInsight
                secondaryMetrics
                if isHealthKit {
                    heartRateCard
                }
            }
            .padding()
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

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: family.icon)
                .font(.title)
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(family.color.gradient)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m))
            VStack(alignment: .leading, spacing: 3) {
                Text(record.name).font(.headline)
                HStack(spacing: 4) {
                    Text(record.date, style: .date)
                    Text("(\(record.source))")
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: Hero metrics
    //
    // The 2–3 most important metrics, featured up top in a glass capsule.

    private struct HeroMetric: Identifiable {
        let id = UUID()
        let value: String
        let label: String
    }

    private var heroMetrics: [HeroMetric] {
        var metrics: [HeroMetric] = [
            HeroMetric(value: durationHM(record.durationMinutes), label: "Duration"),
            HeroMetric(value: record.tss.map { "\(Int($0.rounded()))" } ?? "—", label: "TSS"),
        ]
        if let te = record.aerobicTE {
            metrics.append(HeroMetric(value: String(format: "%.1f", te), label: "Aerobic TE"))
        } else if record.distanceKm > 0 {
            metrics.append(HeroMetric(value: String(format: "%.1f km", record.distanceKm), label: "Distance"))
        }
        return metrics
    }

    private var heroCapsule: some View {
        HStack(spacing: 0) {
            ForEach(Array(heroMetrics.enumerated()), id: \.element.id) { index, metric in
                if index > 0 {
                    Divider().frame(height: 34)
                }
                VStack(spacing: Theme.Spacing.xs) {
                    Text(metric.value)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(metric.label)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, Theme.Spacing.l)
        .padding(.horizontal, Theme.Spacing.m)
        .glassSurface(cornerRadius: Theme.Radius.l)
    }

    // MARK: Coach insight ("Silent AI")
    //
    // Static placeholder for now — to be wired to the LLM later. Styled as an
    // insight (glass + a coach-tinted hairline), not a badge.

    private var coachInsight: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            // Text("Controlled aerobic session — pacing stayed in range for a solid endurance stimulus.")
            //     .font(.subheadline)
            // Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.m)
        .glassSurface(cornerRadius: Theme.Radius.m)
        .coachAccent(family.color, cornerRadius: Theme.Radius.m)
    }

    // MARK: Secondary metrics

    private struct SecondaryMetric: Identifiable {
        let id = UUID()
        let label: String
        let value: String
        let icon: String
    }

    private var secondaryMetricList: [SecondaryMetric] {
        var rows: [SecondaryMetric] = []
        // Distance is a hero metric only when there's no Aerobic TE; otherwise
        // it lives down here.
        if record.aerobicTE != nil, record.distanceKm > 0 {
            rows.append(.init(label: "Distance", value: String(format: "%.2f km", record.distanceKm), icon: "ruler"))
        }
        if let te = record.anaerobicTE {
            rows.append(.init(label: "Anaerobic TE", value: String(format: "%.1f", te), icon: "bolt.heart"))
        }
        if let hr = details["avg_hr"] as? Int {
            rows.append(.init(label: "Avg HR", value: "\(hr) bpm", icon: "heart"))
        }
        if let kcal = details["calories"] as? Int {
            rows.append(.init(label: "Calories", value: "\(kcal) kcal", icon: "flame"))
        }
        return rows
    }

    @ViewBuilder
    private var secondaryMetrics: some View {
        let rows = secondaryMetricList
        if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    HStack {
                        Label(row.label, systemImage: row.icon).font(.subheadline)
                        Spacer()
                        Text(row.value)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Theme.Spacing.s)
                }
            }
            .cardSurface()
        }
    }

    // MARK: Heart rate

    @ViewBuilder
    private var heartRateCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Heart rate").font(.headline)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
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
