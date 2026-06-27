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
// calories) come from the stored `WorkoutRecord` / its `detailsJSON`. The HR
// time-series chart + CSV export are HealthKit-only for now (Garmin HR series
// is not yet stored — see plan's future "deeper Garmin history").

struct TrainingDetailView: View {
    let record: WorkoutRecord

    @State private var heartRateSamples: [HeartRateSample] = []
    @State private var isLoadingHR = false
    @State private var exportFile: ExportFile?
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var showDistanceEdit = false
    @State private var distanceInput = ""

    private var family: SportFamily { SportFamily(sportKey: record.sport) }
    private var structure: PlannedWorkoutStructure? { record.structure }
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
                comparisonCard
                plannedStructureCard
                tssBasisNote
                // coachInsight
                activityCard
                zonesCard
                feelCard
                computedCard
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
        .alert("Override distance", isPresented: $showDistanceEdit) {
            TextField("Distance (km)", text: $distanceInput)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let cleaned = distanceInput.replacingOccurrences(of: ",", with: ".")
                if let km = Double(cleaned), km >= 0 {
                    TrainingDataStore.shared.overrideDistance(activityId: record.id, distanceKm: km)
                }
            }
        } message: {
            Text("Manually set this activity's distance. Recomputes its TSS; survives the next Garmin sync.")
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
        if record.distanceKm > 0 {
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

    // MARK: Planned vs Completed
    //
    // When this record originated from a plan, the planned section survives the
    // ingest fold — so we can show target vs achieved side by side. Deltas are
    // neutral (over/under target is not framed as good or bad).

    private struct ComparisonMetric: Identifiable {
        let id = UUID()
        let label: String
        let planned: String
        let completed: String
        let delta: String?
    }

    private var comparisonMetrics: [ComparisonMetric] {
        guard record.isPlanned else { return [] }
        var rows: [ComparisonMetric] = []

        let plannedMinutes = record.plannedDurationMinutes
        if plannedMinutes > 0, record.durationMinutes > 0 {
            rows.append(.init(label: "Duration",
                              planned: durationHM(plannedMinutes),
                              completed: durationHM(record.durationMinutes),
                              delta: signedDuration(record.durationMinutes - plannedMinutes)))
        }

        if let planned = record.plannedDistance, planned.meters > 0, record.distanceKm > 0 {
            let plannedKm = planned.meters / 1000
            let prefix = planned.source == .fixed ? "" : "~"
            rows.append(.init(label: "Distance",
                              planned: prefix + String(format: "%.2f km", plannedKm),
                              completed: String(format: "%.2f km", record.distanceKm),
                              delta: signedKm(record.distanceKm - plannedKm)))
        }

        let targetTSS = record.resolvedTargetTSS
        if targetTSS > 0, let actualTSS = record.tss {
            let prefix = record.isEstimatedTSS ? "~" : ""
            rows.append(.init(label: "TSS",
                              planned: prefix + "\(Int(targetTSS.rounded()))",
                              completed: "\(Int(actualTSS.rounded()))",
                              delta: signedInt(actualTSS - targetTSS)))
        }
        return rows
    }

    @ViewBuilder
    private var comparisonCard: some View {
        let rows = comparisonMetrics
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Label("Planned vs Completed", systemImage: "arrow.left.arrow.right")
                    .font(.headline)
                Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.m,
                     verticalSpacing: Theme.Spacing.s) {
                    GridRow {
                        Text("")
                        Text("Planned").gridColumnAlignment(.trailing)
                        Text("Completed").gridColumnAlignment(.trailing)
                        Text("Δ").gridColumnAlignment(.trailing)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(rows) { row in
                        Divider().gridCellColumns(4)
                        GridRow {
                            Text(row.label).font(.subheadline)
                            Text(row.planned)
                                .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                            Text(row.completed)
                                .font(.subheadline.weight(.semibold)).monospacedDigit()
                            Text(row.delta ?? "—")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }

    @ViewBuilder
    private var plannedStructureCard: some View {
        if record.isPlanned, let structure, !structure.steps.isEmpty {
            PlannedStructureCard(structure: structure, accent: family.color,
                                 title: "Planned structure")
        }
    }

    // Signed deltas — `nil` when the difference rounds away to nothing.
    private func signedDuration(_ minutes: Double) -> String? {
        guard abs(minutes) >= 0.5 else { return nil }
        return (minutes >= 0 ? "+" : "−") + durationHM(abs(minutes))
    }
    private func signedKm(_ km: Double) -> String? {
        guard abs(km) >= 0.01 else { return nil }
        return (km >= 0 ? "+" : "−") + String(format: "%.2f km", abs(km))
    }
    private func signedInt(_ value: Double) -> String? {
        let rounded = Int(value.rounded())
        guard rounded != 0 else { return nil }
        return (rounded > 0 ? "+" : "−") + "\(abs(rounded))"
    }

    // MARK: TSS provenance
    //
    // Surface where the TSS came from. Completed activities derive TSS
    // from their stored stream data via `TSSCalculator` — we re-run the same
    // dispatch (read-only) against the current thresholds to label the source.

    private var tssBasis: String? {
        guard record.tss != nil else { return nil }
        // As-of the activity's own date — the same basis it was scored with at ingest.
        let snapshot = TrainingDataStore.shared.performanceHistory().snapshot(asOf: record.date)
        return TSSCalculator.compute(details: details, snapshot: snapshot).basis?.label
    }

    @ViewBuilder
    private var tssBasisNote: some View {
        if let tssBasis {
            Label("TSS computed from \(tssBasis)", systemImage: "function")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Spacing.xs)
        }
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

    // MARK: Activity metrics
    //
    // The achieved summary, sport-aware. Each row is conditional, so a sparse
    // record (e.g. a HealthKit workout) simply shows fewer rows. Self-computed
    // normalized values live in `computedCard`; zones + feel are their own cards.

    private struct SecondaryMetric: Identifiable {
        let id = UUID()
        let label: String
        let value: String
        let icon: String
    }

    private var activityMetricList: [SecondaryMetric] {
        var rows: [SecondaryMetric] = []
        let running = details["running"] as? [String: Any]
        let cycling = details["cycling"] as? [String: Any]
        let swimming = details["swimming"] as? [String: Any]

        if let hr = Coerce.int(details["avg_hr"]) {
            rows.append(.init(label: "Avg HR", value: "\(hr) bpm", icon: "heart"))
        }
        if let hr = Coerce.int(details["max_hr"]) {
            rows.append(.init(label: "Max HR", value: "\(hr) bpm", icon: "heart.fill"))
        }
        if let te = record.aerobicTE {
            rows.append(.init(label: "Aerobic TE", value: String(format: "%.1f", te), icon: "lungs"))
        }
        if let te = record.anaerobicTE {
            rows.append(.init(label: "Anaerobic TE", value: String(format: "%.1f", te), icon: "bolt.heart"))
        }
        if let cadence = Coerce.int(running?["avg_cadence_spm"]) {
            rows.append(.init(label: "Avg Cadence", value: "\(cadence) spm", icon: "figure.run"))
        } else if let cadence = Coerce.int(cycling?["avg_cadence_rpm"]) {
            rows.append(.init(label: "Avg Cadence", value: "\(cadence) rpm", icon: "bicycle"))
        }
        if let power = Coerce.int(cycling?["avg_power_w"]) ?? Coerce.int(running?["avg_power_w"]) {
            rows.append(.init(label: "Avg Power", value: "\(power) W", icon: "bolt"))
        }
        if let speed = Coerce.double(cycling?["avg_speed_kmh"]), speed > 0 {
            var value = String(format: "%.1f km/h", speed)
            if let maxSpeed = Coerce.double(cycling?["max_speed_kmh"]), maxSpeed > 0 {
                value += String(format: " (max %.1f)", maxSpeed)
            }
            rows.append(.init(label: "Avg Speed", value: value, icon: "speedometer"))
        }
        if let swolf = Coerce.int(swimming?["avg_swolf"]) {
            rows.append(.init(label: "Avg SWOLF", value: "\(swolf)", icon: "figure.pool.swim"))
        }
        if let pace = Coerce.string(swimming?["avg_pace_per_100m"]) {
            rows.append(.init(label: "Avg Pace", value: "\(pace) /100m", icon: "speedometer"))
        }
        if let gain = Coerce.int(details["elevation_gain_m"]), gain > 0 {
            var value = "↑ \(gain) m"
            if let loss = Coerce.int(details["elevation_loss_m"]), loss > 0 {
                value += "   ↓ \(loss) m"
            }
            rows.append(.init(label: "Elevation", value: value, icon: "mountain.2"))
        }
        if let kcal = Coerce.int(details["calories"]) {
            rows.append(.init(label: "Calories", value: "\(kcal) kcal", icon: "flame"))
        }
        return rows
    }

    @ViewBuilder
    private var activityCard: some View {
        let rows = activityMetricList
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("Activity").font(.headline)
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }

    // MARK: Zones — time-in-zone distribution (HR and, for cycling, power)

    private let zonePalette: [Color] = [
        Theme.Palette.info, Theme.Palette.success, .yellow,
        Theme.Palette.warning, Theme.Palette.danger,
    ]

    /// `z1…z5` seconds from a zone dict, or `[]` when absent / all-zero.
    private func zoneSeconds(_ dict: [String: Any]?) -> [Double] {
        guard let dict else { return [] }
        let zones = (1...5).map { Coerce.double(dict["z\($0)"]) ?? 0 }
        return zones.reduce(0, +) > 0 ? zones : []
    }

    @ViewBuilder
    private var zonesCard: some View {
        let hr = zoneSeconds(details["hr_zones_seconds"] as? [String: Any])
        let power = zoneSeconds((details["cycling"] as? [String: Any])?["power_zones_seconds"] as? [String: Any])
        if !hr.isEmpty || !power.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text("Time in zone").font(.headline)
                if !hr.isEmpty { zoneBar("Heart rate", zones: hr) }
                if !power.isEmpty { zoneBar("Power", zones: power) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }

    private func zoneBar(_ title: String, zones: [Double]) -> some View {
        let total = max(1, zones.reduce(0, +))
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(zones.enumerated()), id: \.offset) { index, seconds in
                        if seconds > 0 {
                            zonePalette[min(index, zonePalette.count - 1)]
                                .frame(width: max(2, geo.size.width * seconds / total))
                        }
                    }
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            HStack(spacing: Theme.Spacing.m) {
                ForEach(Array(zones.enumerated()), id: \.offset) { index, seconds in
                    if seconds > 0 {
                        HStack(spacing: 3) {
                            Circle().fill(zonePalette[min(index, zonePalette.count - 1)])
                                .frame(width: 7, height: 7)
                            Text("Z\(index + 1)").font(.caption2).foregroundStyle(.secondary)
                            Text(zoneTime(seconds)).font(.caption2).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func zoneTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? "\(total / 60)m" : "\(total)s"
    }

    // MARK: Feel & RPE — the athlete's subjective read on the session

    @ViewBuilder
    private var feelCard: some View {
        let feel = Coerce.int(details["feel"])
        let rpe = Coerce.int(details["rpe"])
        let comment = Coerce.string(details["notes"])
        if feel != nil || rpe != nil || (comment?.isEmpty == false) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Label("How it felt", systemImage: "face.smiling").font(.headline)
                if let feel {
                    metricRow("Feel", feelLabel(feel), "face.smiling")
                }
                if let rpe {
                    metricRow("RPE", "\(rpe) / 10", "gauge.with.dots.needle.bottom.50percent")
                }
                if let comment, !comment.isEmpty {
                    Text(comment).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }

    private func feelLabel(_ value: Int) -> String {
        switch value {
        case ...1: return "Very Weak"
        case 2:    return "Weak"
        case 3:    return "Normal"
        case 4:    return "Strong"
        default:   return "Very Strong"
        }
    }

    // MARK: Computed values (our self-computed TSS inputs) + distance override

    /// The normalized inputs we derive ourselves (vs Garmin's raw values).
    private var computedRows: [SecondaryMetric] {
        var rows: [SecondaryMetric] = []
        if let pace = Coerce.double((details["running"] as? [String: Any])?["normalized_pace_s_per_km"]), pace > 0 {
            rows.append(.init(label: "Normalized Pace", value: paceLabel(pace), icon: "speedometer"))
        }
        if let np = Coerce.double((details["cycling"] as? [String: Any])?["normalized_power_w"]), np > 0 {
            rows.append(.init(label: "Normalized Power", value: "\(Int(np)) W", icon: "bolt"))
        }
        if let swim = details["swimming"] as? [String: Any],
           let cleaned = Coerce.double(swim["cleaned_distance_m"]),
           let garmin = Coerce.double(swim["garmin_distance_m"]), garmin > 0, cleaned > 0 {
            let pct = Int(((garmin / cleaned) - 1) * 100)
            rows.append(.init(label: "Cleaned lengths",
                              value: "\(Int(cleaned)) m (Garmin \(Int(garmin)) m, \(pct >= 0 ? "+" : "")\(pct)%)",
                              icon: "ruler"))
        }
        return rows
    }

    private var computedCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Text("Computed").font(.headline)
                Spacer()
                Button {
                    distanceInput = String(format: "%.2f", record.distanceKm)
                    showDistanceEdit = true
                } label: {
                    Label("Edit distance", systemImage: "pencil")
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
            metricRow("Distance", String(format: "%.2f km", record.distanceKm), "ruler")
            ForEach(computedRows) { row in
                metricRow(row.label, row.value, row.icon)
            }
        }
        .cardSurface()
    }

    private func metricRow(_ label: String, _ value: String, _ icon: String) -> some View {
        HStack {
            Label(label, systemImage: icon).font(.subheadline)
            Spacer()
            Text(value).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private func paceLabel(_ secPerKm: Double) -> String {
        let s = Int(secPerKm.rounded())
        return String(format: "%d:%02d /km", s / 60, s % 60)
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
