import SwiftUI
import Charts
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Training Detail View
//
// Per-activity detail. Summary metrics (duration, distance, TSS, avg HR,
// calories) come from the stored `WorkoutRecord` / its `detailsJSON`; the
// time-series charts render the stored `streamsData` streams, source-agnostic.

struct TrainingDetailView: View {
    let record: WorkoutRecord

    /// The legs of a multisport session, prepared for display. Decoded once in
    /// `init` — `record.segments` parses `segmentsJSON` on every access.
    private let legs: [Leg]

    /// One leg, with the name and color it carries through strip, splits and
    /// chart bands. `name` is unique within the race so it can identify a row.
    private struct Leg: Identifiable {
        let index: Int
        let segment: WorkoutSegment
        let name: String
        let color: Color
        var id: Int { index }
    }

    init(record: WorkoutRecord) {
        self.record = record
        let segments = record.segments
        let totals = segments.reduce(into: [String: Int]()) { $0[$1.sport, default: 0] += 1 }
        var seen: [String: Int] = [:]
        self.legs = segments.enumerated().map { index, segment in
            seen[segment.sport, default: 0] += 1
            let ordinal = seen[segment.sport] ?? 1
            let title = Self.legTitle(segment)
            return Leg(
                index: index,
                segment: segment,
                name: segment.isTransition ? "T\(ordinal)"
                    : (totals[segment.sport] ?? 1) > 1 ? "\(title) \(ordinal)" : title,
                color: segment.isTransition ? .gray : segment.family.color)
        }
    }

    /// nil = the Total tab; otherwise the index into `legs`.
    @State private var selectedLeg: Int?
    /// Regular-width (iPad / Mac) two-pane layout. Measured, not size-class — a
    /// narrow iPad split view gets the phone column.
    @State private var isWide = false
    @State private var exportFile: ExportFile?
    @State private var actionError: String?
    @State private var showDistanceEdit = false
    @State private var distanceInput = ""
    @State private var showRenameEdit = false
    @State private var nameInput = ""
    @State private var showDeleteConfirm = false
    @State private var showTSSBasis = false
    @State private var showUnlinkConfirm = false
    @State private var showIgnoreConfirm = false
    @State private var editingSets: [StrengthSets.SetRow]?
    @Environment(\.dismiss) private var dismiss

    private var family: SportFamily { SportFamily(sportKey: record.sport) }
    private var structure: PlannedWorkoutStructure? { record.structure }
    private var details: [String: Any] {
        guard let data = record.detailsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }
    private var isHealthKit: Bool { record.source == "healthkit" }

    /// Multisport rows are marked (and tinted) by the link glyph, not by the
    /// `.other` family their parent sport key falls into.
    private var accent: Color { legs.isEmpty ? family.color : .accentColor }

    /// The stored id of this row's completed activity — the row's own id, or the
    /// fold link when the actuals live on a plan row.
    private var completedActivityId: String {
        record.externalRefs[TrainingDataStore.completedRefKey] ?? record.id
    }

    /// Open plans this standalone completed activity could be linked to, nearest
    /// planned day first. Empty unless the row is a standalone completed activity.
    private var linkCandidates: [WorkoutRecord] {
        guard record.isCompleted, !record.isPlanned else { return [] }
        return TrainingDataStore.shared.openPlansMatching(activity: record)
    }

    private func planMenuLabel(_ plan: WorkoutRecord) -> String {
        let day = plan.date.formatted(.dateTime.day().month())
        guard plan.targetDurationMinutes > 0 else { return "\(plan.name) · \(day)" }
        return "\(plan.name) · \(Int(plan.targetDurationMinutes)) min · \(day)"
    }

    var body: some View {
        ScrollView {
            Group {
                if isWide { wideBody } else { compactBody }
            }
            .padding()
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 1000 } action: { isWide = $0 }
        .navigationTitle(family.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if record.isPlanned, record.isCompleted {
                        Button { showUnlinkConfirm = true } label: {
                            Label("Unlink actual", systemImage: "personalhotspot.slash")
                        }
                    }
                    if !linkCandidates.isEmpty {
                        Menu {
                            ForEach(linkCandidates, id: \.id) { plan in
                                Button {
                                    TrainingDataStore.shared.linkActual(activityId: record.id, toPlanId: plan.id)
                                    dismiss()
                                } label: {
                                    Text(planMenuLabel(plan))
                                }
                            }
                        } label: {
                            Label("Link to planned workout", systemImage: "link.badge.plus")
                        }
                    }
                    Button {
                        nameInput = record.name
                        showRenameEdit = true
                    } label: {
                        Label("Rename", systemImage: "pencil.line")
                    }
                    if family != .strength {
                        Button {
                            distanceInput = String(format: "%.2f", record.distanceKm)
                            showDistanceEdit = true
                        } label: {
                            Label("Edit distance", systemImage: "pencil")
                        }
                    }
                    if debugModeEnabled {
                        Button(action: exportDebugJSON) {
                            Label("Export workout (JSON)", systemImage: "ladybug")
                        }
                        if completedActivityId.hasPrefix("garmin:") || completedActivityId.hasPrefix("healthkit:") {
                            Button {
                                Task {
                                    let ok = await DataSyncCoordinator.shared.refetchActivity(
                                        id: completedActivityId, date: record.date)
                                    if !ok { actionError = "Refetch failed — source unavailable." }
                                }
                            } label: {
                                Label("Refetch from source", systemImage: "arrow.clockwise")
                            }
                        }
                        Button {
                            TrainingDataStore.shared.rescoreActivity(id: record.id)
                        } label: {
                            Label("Recalculate TSS", systemImage: "function")
                        }
                    }
                    if record.isCompleted, !record.isPlanned {
                        Button(role: .destructive) {
                            showIgnoreConfirm = true
                        } label: {
                            Label("Ignore workout", systemImage: "eye.slash")
                        }
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete workout", systemImage: "trash")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Delete this workout?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                TrainingDataStore.shared.deleteActivity(id: record.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the stored row. A full re-sync of its source re-creates it — use this to verify the sync rebuilds the record.")
        }
        .confirmationDialog("Unlink this activity from its plan?", isPresented: $showUnlinkConfirm, titleVisibility: .visible) {
            Button("Unlink", role: .destructive) {
                TrainingDataStore.shared.unlinkActual(planId: record.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Splits this row into the open plan and a standalone activity, so you can link the correct activity to the plan.")
        }
        .confirmationDialog("Ignore this workout?", isPresented: $showIgnoreConfirm, titleVisibility: .visible) {
            Button("Ignore", role: .destructive) {
                TrainingDataStore.shared.ignoreActivity(id: record.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes this workout and stops it from re-syncing — for a duplicate recorded on another device. Restore it anytime from Settings → Ignored workouts.")
        }
        .sheet(item: $exportFile) { file in ShareSheet(items: [file.url]) }
        .sheet(isPresented: Binding(get: { editingSets != nil }, set: { if !$0 { editingSets = nil } })) {
            StrengthSetsEditorSheet(activityId: record.id, rows: editingSets ?? [])
        }
        .alert("Action failed", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .alert("Rename workout", isPresented: $showRenameEdit) {
            TextField("Name", text: $nameInput)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    TrainingDataStore.shared.renameActivity(id: record.id, name: trimmed)
                }
            }
        } message: {
            Text("Overrides the workout's name; survives the next sync.")
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

    // MARK: Layouts
    //
    // One card set, two arrangements: the phone column, and — from ~1000pt of
    // width — two panes, a fixed summary rail beside the charts tiled across the
    // rest, so a wide window doesn't push every chart below the fold. The title
    // and (multisport) the segment strip span both panes and never move.

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            header
            heroCapsule
            comparisonCard
            plannedStructureCard
            if legs.isEmpty {
                strengthCard(details)
                activityCard(details)
                zonesCard(details)
                feelCard
                streamsSection(record.streamsData, details: details, family: family)
                swimSection(details)
            } else {
                multisportSection
            }
        }
    }

    private var wideBody: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            // Single sport needs no heading here: the navigation title already
            // names it, and the rail carries the workout's own header card.
            if !legs.isEmpty {
                header
                segmentStrip
            }
            HStack(alignment: .top, spacing: Theme.Spacing.l) {
                VStack(spacing: Theme.Spacing.m) { rail }
                    .frame(width: 372)
                VStack(spacing: Theme.Spacing.m) { chartPane }
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// The left rail: identity and every number, top to bottom. Its last card
    /// stretches so both panes end flush.
    @ViewBuilder
    private var rail: some View {
        if let leg = selectedLegValue {
            totalsCard(totalsMetrics(leg.segment.durationMinutes, leg.segment.tss, leg.segment.distanceKm,
                                     family: leg.segment.family),
                       basis: leg.segment.tssBasis)
            activityCard(leg.segment.details, title: "\(leg.name) · Metrics")
            zonesCard(leg.segment.details)
        } else {
            if legs.isEmpty { header.cardSurface() }
            totalsCard(heroMetrics, basis: tssBasis)
            comparisonCard
            plannedStructureCard
            activityCard(details, title: legs.isEmpty ? "Activity" : "Metrics", extra: transitionsRow)
            feelCard
            zonesCard(details)
                .frame(maxHeight: legs.isEmpty ? .infinity : nil, alignment: .top)
        }
        // The splits card is the race's index — it stays on every tab.
        if !legs.isEmpty {
            splitsCard.frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// The right pane: the workout's defining metric full width, the rest tiled
    /// two-up. A card drops with its stream and the grid reflows.
    @ViewBuilder
    private var chartPane: some View {
        if let leg = selectedLegValue {
            let models = WorkoutStreamModel.models(from: leg.segment.streamsData, details: leg.segment.details,
                                                   family: leg.segment.family)
            chartGrid(models, siblings: models, columns: models.count > 2 ? 2 : 1, height: 168)
            swimSection(leg.segment.details)
        } else if legs.isEmpty {
            strengthCard(details)
            let models = WorkoutStreamModel.models(from: record.streamsData, details: details, family: family)
            if let primary = models.first {
                WorkoutStreamCard(title: primary.kind.label, model: primary, siblings: models, height: 180)
            }
            chartGrid(Array(models.dropFirst()), siblings: models, columns: 2, height: 150)
            swimSection(details)
        } else {
            let models = WorkoutStreamModel.raceModels(segments: legs.map(\.segment))
            chartGrid(models, siblings: models, columns: 1, height: 168,
                      bands: raceBands, suffix: " · full race")
        }
    }

    private func chartGrid(_ models: [WorkoutStreamModel], siblings: [WorkoutStreamModel],
                           columns: Int, height: CGFloat,
                           bands: [WorkoutStreamChart.Band] = [], suffix: String = "") -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.m), count: columns),
            spacing: Theme.Spacing.m
        ) {
            ForEach(models) { model in
                WorkoutStreamCard(title: model.kind.label + suffix, model: model,
                                  siblings: siblings, bands: bands, height: height)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: legs.isEmpty ? family.icon : "link")
                .font(.title)
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(accent.gradient)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m))
            VStack(alignment: .leading, spacing: 3) {
                Text(record.name).font(.headline)
                HStack(spacing: 4) {
                    if let time = Coerce.string(details["time"]), !time.isEmpty {
                        Text(time)
                    }
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

    /// The totals of a workout or of one multisport leg.
    private func totalsMetrics(_ durationMinutes: Double, _ tss: Double?, _ distanceKm: Double,
                               family: SportFamily) -> [HeroMetric] {
        var metrics: [HeroMetric] = [
            HeroMetric(value: durationHM(durationMinutes), label: "Duration"),
            HeroMetric(value: tss.map { "\(Int($0.rounded()))" } ?? "—", label: "TSS"),
        ]
        if distanceKm > 0 {
            metrics.append(HeroMetric(value: family.distanceLabel(distanceKm, decimals: 1), label: "Distance"))
        }
        return metrics
    }

    private var heroMetrics: [HeroMetric] {
        totalsMetrics(record.durationMinutes, record.tss, record.distanceKm, family: family)
    }

    private func totalsRow(_ metrics: [HeroMetric], basis: String?) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                if index > 0 {
                    Divider().frame(height: 34)
                }
                heroCell(metric, basis: basis)
            }
        }
        .padding(.vertical, Theme.Spacing.l)
        .padding(.horizontal, Theme.Spacing.m)
    }

    private var heroCapsule: some View {
        totalsRow(heroMetrics, basis: tssBasis).glassSurface(cornerRadius: Theme.Radius.l)
    }

    /// The rail's totals — numbers belong on the opaque content layer.
    private func totalsCard(_ metrics: [HeroMetric], basis: String?) -> some View {
        totalsRow(metrics, basis: basis).frame(maxWidth: .infinity).cardSurface()
    }

    /// The TSS cell reveals its computation basis in a popover on tap.
    @ViewBuilder
    private func heroCell(_ metric: HeroMetric, basis: String?) -> some View {
        let cell = VStack(spacing: Theme.Spacing.xs) {
            Text(metric.value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(metric.label)
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        if metric.label == "TSS", let basis {
            cell
                .contentShape(Rectangle())
                .onTapGesture { showTSSBasis = true }
                .popover(isPresented: $showTSSBasis, arrowEdge: .top) {
                    Label("TSS computed from \(basis)", systemImage: "function")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 280)
                        .padding()
                        .presentationCompactAdaptation(.popover)
                }
        } else {
            cell
        }
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
                              planned: prefix + family.distanceLabel(plannedKm),
                              completed: family.distanceLabel(record.distanceKm),
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
        return (km >= 0 ? "+" : "−") + family.distanceLabel(abs(km))
    }
    private func signedInt(_ value: Double) -> String? {
        let rounded = Int(value.rounded())
        guard rounded != 0 else { return nil }
        return (rounded > 0 ? "+" : "−") + "\(abs(rounded))"
    }

    // MARK: TSS provenance
    //
    // Surface where the TSS came from (via the hero TSS popover). Completed
    // activities derive TSS from their stored stream data via `TSSCalculator` —
    // we re-run the same dispatch (read-only) to label the source.

    /// The HR readings this row was scored from — the stored histogram, the same
    /// input `rescoreAllActivities` replays. Empty for a row written before histograms.
    private var storedHeartRateSamples: [NormalizedStream.Sample] {
        (ZoneHistogram.decode(record.zoneHistogramData) ?? [:])[.heartRate] ?? []
    }

    private var tssBasis: String? {
        guard record.tss != nil else { return nil }
        // As-of the activity's own date — the same basis it was scored with at ingest.
        let snapshot = TrainingDataStore.shared.performanceHistory().snapshot(asOf: record.date)
        return TSSCalculator.compute(details: details, snapshot: snapshot,
                                     heartRate: storedHeartRateSamples).basis?.label
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
    // values (normalized pace/power, cleaned swim distance) carry the ƒ icon;
    // zones + feel are their own cards.

    private struct SecondaryMetric: Identifiable {
        let id = UUID()
        let label: String
        let value: String
        let icon: String
    }

    private func activityMetricList(_ details: [String: Any]) -> [SecondaryMetric] {
        var rows: [SecondaryMetric] = []
        let running = details["running"] as? [String: Any]
        let cycling = details["cycling"] as? [String: Any]
        let swimming = details["swimming"] as? [String: Any]

        if let hr = Coerce.int(details["avg_hr"]) {
            var value = "\(hr) bpm"
            if let maxHr = Coerce.int(details["max_hr"]) {
                value += " (max \(maxHr))"
            }
            rows.append(.init(label: "Avg HR", value: value, icon: "heart"))
        }
        if let cadence = Coerce.int(running?["avg_cadence_spm"]) {
            rows.append(.init(label: "Avg Cadence", value: "\(cadence) spm", icon: "figure.run"))
        } else if let cadence = Coerce.int(cycling?["avg_cadence_rpm"]) {
            rows.append(.init(label: "Avg Cadence", value: "\(cadence) rpm", icon: "bicycle"))
        }
        if let power = Coerce.int(cycling?["avg_power_w"]) ?? Coerce.int(running?["avg_power_w"]) {
            rows.append(.init(label: "Avg Power", value: "\(power) W", icon: "bolt"))
        }
        if let np = Coerce.double(cycling?["normalized_power_w"]), np > 0 {
            rows.append(.init(label: "Normalized Power", value: "\(Int(np)) W", icon: "function"))
        }
        if let pace = Coerce.double(running?["normalized_pace_s_per_km"]), pace > 0 {
            rows.append(.init(label: "Normalized Pace", value: paceLabel(pace), icon: "function"))
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
        if let cleaned = Coerce.double(swimming?["cleaned_distance_m"]),
           let garmin = Coerce.double(swimming?["garmin_distance_m"]), garmin > 0, cleaned > 0 {
            let pct = Int(((garmin / cleaned) - 1) * 100)
            rows.append(.init(label: "Cleaned lengths",
                              value: "\(Int(cleaned)) m (Garmin \(Int(garmin)) m, \(pct >= 0 ? "+" : "")\(pct)%)",
                              icon: "function"))
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
    private func activityCard(_ details: [String: Any], title: String = "Activity",
                              extra: [SecondaryMetric] = []) -> some View {
        let rows = activityMetricList(details) + extra
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text(title).font(.headline)
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

    // MARK: Zones — time-in-zone distribution, per metric this workout recorded

    @ViewBuilder
    private func zonesCard(_ details: [String: Any]) -> some View {
        let zones: [ZoneMetric: [Double]] = ZoneMetric.allCases.reduce(into: [:]) {
            $0[$1] = ZoneDistribution.zoneSeconds(details: details, metric: $1)
        }
        // The bounds this workout was actually bucketed against, not today's.
        let bounds: [ZoneMetric: [Double]] = ZoneMetric.allCases.reduce(into: [:]) {
            $0[$1] = ZoneDistribution.zoneBounds(details: details, metric: $1)
        }
        if !ZoneDistributionStack.isEmpty(zones) {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text("Time in zone").font(.headline)
                ZoneDistributionStack(seconds: zones, bounds: bounds)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
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

    // MARK: Metric streams — one chart per stored time-series metric

    // MARK: Segments — the legs of a multisport session
    //
    // A segment tab strip (Garmin Connect's pattern) replaces one endless scroll
    // through every leg: title, totals and strip stay put, only the blocks below
    // swap. Each leg renders through the same cards as a standalone workout —
    // its details dict has the identical schema and it carries its own streams,
    // TSS and basis. "Total" keeps the whole-race view.

    /// The leg the strip has selected; nil on the Total tab.
    private var selectedLegValue: Leg? {
        selectedLeg.flatMap { $0 < legs.count ? legs[$0] : nil }
    }

    @ViewBuilder
    private var multisportSection: some View {
        segmentStrip
        if let leg = selectedLegValue {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Text(leg.name).font(.title3.weight(.bold))
                Text(legSummary(leg.segment))
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            activityCard(leg.segment.details, title: "Metrics")
            zonesCard(leg.segment.details)
            streamsSection(leg.segment.streamsData, details: leg.segment.details,
                               family: leg.segment.family)
            swimSection(leg.segment.details)
        } else {
            splitsCard
            activityCard(details, title: "Metrics", extra: transitionsRow)
            zonesCard(details)
            feelCard
            raceCharts
        }
    }

    private var segmentStrip: some View {
        HStack(spacing: 2) {
            segmentTab(nil)
            ForEach(legs) { segmentTab($0) }
        }
        .background(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 1)
        }
    }

    private func segmentTab(_ leg: Leg?) -> some View {
        let active = selectedLeg == leg?.index
        let color = leg?.color ?? accent
        return Button {
            selectedLeg = leg?.index
        } label: {
            VStack(spacing: 3) {
                Image(systemName: leg.map(Self.legIcon) ?? "link")
                    .font(.footnote)
                    .foregroundStyle(active ? color : .secondary)
                Text(Self.elapsed(leg?.segment.durationMinutes ?? record.durationMinutes))
                    .font(.caption.weight(.bold)).monospacedDigit()
                    .foregroundStyle(active ? .primary : .secondary)
                Text(tabDetail(leg))
                    .font(.caption2)
                    .foregroundStyle(active ? .secondary : .tertiary)
            }
            .lineLimit(1).minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.s)
            .background(
                active ? color.opacity(0.12) : .clear,
                in: .rect(topLeadingRadius: Theme.Radius.s, topTrailingRadius: Theme.Radius.s)
            )
            .overlay(alignment: .bottom) {
                Rectangle().fill(active ? color : .clear).frame(height: 2)
            }
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: active)
    }

    /// The tab's secondary line: the race distance for Total, else the leg's own
    /// rate — falling back to its distance for a transition, which has no rate.
    private func tabDetail(_ leg: Leg?) -> String {
        guard let leg else { return family.distanceLabel(record.distanceKm, decimals: 1) }
        if let rate = Self.rateLabel(leg.segment.details) { return rate }
        return leg.segment.distanceKm > 0 ? leg.segment.family.distanceLabel(leg.segment.distanceKm) : "—"
    }

    // MARK: Splits — the race broken into its legs (Total tab)

    private var splitsCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Splits").font(.headline)
            ProportionBar(
                segments: legs.map {
                    .init(label: $0.name, color: $0.color,
                          value: $0.segment.durationMinutes, display: "")
                },
                showLegend: false)
            VStack(spacing: Theme.Spacing.s) {
                ForEach(legs) { leg in
                    Button { selectedLeg = leg.index } label: { splitRow(leg) }
                        .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func splitRow(_ leg: Leg) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: Self.legIcon(leg))
                .font(.subheadline)
                .foregroundStyle(leg.color)
                .frame(width: 30, height: 30)
                .background(leg.color.opacity(0.17),
                            in: .rect(cornerRadius: Theme.Radius.s, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(leg.name).font(.subheadline.weight(.semibold))
                Text(splitDetail(leg)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Self.elapsed(leg.segment.durationMinutes))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                Text(leg.segment.tss.map { "\(Int($0.rounded())) TSS" } ?? "—")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    /// "40.2 km · 32.0 km/h" — the leg's distance and rate; a transition names
    /// the disciplines it sits between instead, having neither rate nor pace.
    private func splitDetail(_ leg: Leg) -> String {
        var parts: [String] = []
        if leg.segment.distanceKm > 0 {
            parts.append(leg.segment.family.distanceLabel(leg.segment.distanceKm))
        }
        if let rate = Self.rateLabel(leg.segment.details) {
            parts.append(rate)
        } else if leg.segment.isTransition {
            let neighbours = [legs.first { $0.index < leg.index && !$0.segment.isTransition },
                              legs.first { $0.index > leg.index && !$0.segment.isTransition }]
            parts.append(neighbours.compactMap { $0?.segment.family.displayName }.joined(separator: " → "))
        }
        return parts.joined(separator: " · ")
    }

    /// Time spent in transition — a race total the leg cards can't show.
    private var transitionsRow: [SecondaryMetric] {
        let minutes = legs.filter(\.segment.isTransition).reduce(0) { $0 + $1.segment.durationMinutes }
        guard minutes > 0 else { return [] }
        return [.init(label: "Transitions", value: Self.elapsed(minutes) + " total", icon: "clock")]
    }

    /// The legs shaded behind a race-long trace.
    private var raceBands: [WorkoutStreamChart.Band] {
        legs.map {
            WorkoutStreamChart.Band(
                start: $0.segment.offsetSeconds,
                end: $0.segment.offsetSeconds + $0.segment.durationMinutes * 60,
                color: $0.color)
        }
    }

    /// The race-long traces, with the legs shaded behind them.
    @ViewBuilder
    private var raceCharts: some View {
        let models = WorkoutStreamModel.raceModels(segments: legs.map(\.segment))
        ForEach(models) { model in
            WorkoutStreamCard(title: "\(model.kind.label) · full race", model: model,
                              siblings: models, bands: raceBands)
        }
    }

    private static func legIcon(_ leg: Leg) -> String {
        leg.segment.isTransition ? "chevron.right.2" : leg.segment.family.icon
    }

    /// The leg's family name, except for the sports the families collapse into
    /// `.other` — a triathlon's transitions above all, which would otherwise all
    /// read "Other". Those show their own sport key ("transition" → "Transition").
    private static func legTitle(_ segment: WorkoutSegment) -> String {
        guard segment.family == .other else { return segment.family.displayName }
        return segment.sport.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// "1:12:04 · 40.2 km · 118 TSS" — the parts this leg actually measured.
    private func legSummary(_ segment: WorkoutSegment) -> String {
        var parts = [Self.elapsed(segment.durationMinutes)]
        if segment.distanceKm > 0 { parts.append(segment.family.distanceLabel(segment.distanceKm)) }
        if let tss = segment.tss { parts.append("\(Int(tss.rounded())) TSS") }
        return parts.joined(separator: " · ")
    }

    /// The measured average rate of a details dict — pace for swim and run,
    /// speed for the bike. Nil when the sport has none (a transition).
    private static func rateLabel(_ details: [String: Any]) -> String? {
        if let pace = Coerce.string((details["swimming"] as? [String: Any])?["avg_pace_per_100m"]) {
            return "\(pace) /100m"
        }
        if let pace = Coerce.string((details["running"] as? [String: Any])?["avg_pace_min_km"]) {
            return "\(pace) /km"
        }
        if let speed = Coerce.double((details["cycling"] as? [String: Any])?["avg_speed_kmh"]), speed > 0 {
            return String(format: "%.1f km/h", speed)
        }
        return nil
    }

    /// Elapsed split time — `h:mm:ss` over an hour, else `m:ss`.
    private static func elapsed(_ minutes: Double) -> String {
        let s = Int((minutes * 60).rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    @ViewBuilder
    private func streamsSection(_ data: Data, details: [String: Any],
                                family: SportFamily) -> some View {
        let models = WorkoutStreamModel.models(from: data, details: details, family: family)
        ForEach(models) { model in
            WorkoutStreamCard(title: model.kind.label, model: model, siblings: models)
        }
    }

    // MARK: Strength
    //
    // What the watch actually counted, set by set (`strength.exercises`, written
    // at ingest). Garmin's classifier names the exercise itself, so a set the
    // athlete improvised still shows up — this is the record, beside the plan it
    // was linked to. Once the athlete has saved their own corrections, the
    // review is done and no set is flagged any more.

    @ViewBuilder
    private func strengthCard(_ details: [String: Any]) -> some View {
        let rows = StrengthSets.rows(performed: (details["strength"] as? [String: Any])?["exercises"] as? [[String: Any]] ?? [])
        if !rows.isEmpty {
            let corrected = record.overridesJSON.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["strength"] != nil
            let lines = StrengthSets.comparison(planned: WorkoutPayloadBuilder.parseSteps(record.stepsJSON) ?? [],
                                                performed: rows)
                .map { corrected ? StrengthSets.Line(set: $0.set, plan: $0.plan) : $0 }
            ExerciseSetsCard(blocks: [StrengthSets.Block(items: [.exercise(lines)])]) { editingSets = rows }
        }
    }

    // MARK: Swim — per-lap intervals + the cleaned lengths (Garmin per-length data)

    @ViewBuilder
    private func swimSection(_ details: [String: Any]) -> some View {
        let swim = details["swimming"] as? [String: Any]
        if let intervals = swim?["intervals"] as? [[String: Any]], !intervals.isEmpty {
            swimIntervalsCard(intervals)
        }
        if let cleaned = cleanedLengths(details) {
            swimLengthsCard(cleaned)
        }
    }

    /// The same cleaning as ingest (`TSSScoring`), re-run on the stored lengths —
    /// deterministic, so the rows shown always match the scored distance.
    private func cleanedLengths(_ details: [String: Any]) -> SwimCleanResult? {
        guard let swim = details["swimming"] as? [String: Any],
              let pool = Coerce.double(swim["pool_length_m"]), pool > 0,
              let raw = swim["lengths"] as? [[String: Any]], !raw.isEmpty else { return nil }
        return SwimLengthCleaner.clean(SwimLengthCleaner.lengths(from: raw), poolLengthMeters: pool)
    }

    private func swimIntervalsCard(_ intervals: [[String: Any]]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Intervals").font(.headline)
            Grid(alignment: .trailing, horizontalSpacing: Theme.Spacing.m, verticalSpacing: Theme.Spacing.xs) {
                GridRow {
                    Text("#").gridColumnAlignment(.leading)
                    Text("Dist")
                    Text("Time")
                    Text("Pace")
                    Text("SWOLF")
                    Text("Strokes")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                ForEach(Array(intervals.enumerated()), id: \.offset) { _, interval in
                    let isRest = (interval["is_rest"] as? Bool) ?? false
                    GridRow {
                        Text(isRest ? "Rest" : "\(Coerce.int(interval["interval"]) ?? 0)")
                            .gridColumnAlignment(.leading)
                        Text(isRest ? "–" : "\(Int(Coerce.double(interval["distance_m"]) ?? 0)) m")
                        Text(Coerce.string(interval["time_formatted"]) ?? "–")
                        Text(Coerce.string(interval["avg_pace_per_100m"]) ?? "–")
                        Text(Coerce.int(interval["swolf"]).map(String.init) ?? "–")
                        Text(isRest ? "–" : "\(Coerce.int(interval["total_strokes"]) ?? 0)")
                    }
                    .font(.caption.monospacedDigit())
                    .opacity(isRest ? 0.5 : 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func swimLengthsCard(_ cleaned: SwimCleanResult) -> some View {
        DisclosureGroup {
            Grid(alignment: .trailing, horizontalSpacing: Theme.Spacing.m, verticalSpacing: Theme.Spacing.xs) {
                GridRow {
                    Text("#").gridColumnAlignment(.leading)
                    Text("Time")
                    Text("Pace")
                    Text("Strokes")
                    Text("")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                ForEach(Array(cleaned.lengths.enumerated()), id: \.offset) { index, length in
                    GridRow {
                        Text("\(index + 1)").gridColumnAlignment(.leading)
                        Text(lengthTimeLabel(length.durationSeconds))
                        Text(length.distanceMeters > 0
                             ? pace100Label(length.durationSeconds / length.distanceMeters * 100) : "–")
                        Text("\(length.strokes)")
                        if length.absorbedFragment {
                            Image(systemName: "arrow.triangle.merge")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("Rejoined a wrongly-split length")
                        } else if length.splitFromMerged {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("Split from a length that missed a wall-turn")
                        } else {
                            Text("")
                        }
                    }
                    .font(.caption.monospacedDigit())
                }
            }
            .padding(.top, Theme.Spacing.s)
        } label: {
            Text("Lengths (\(cleaned.cleanedLengthCount))").font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// One length's duration, `m:ss.d`.
    private func lengthTimeLabel(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        return String(format: "%d:%04.1f", m, seconds - Double(m * 60))
    }

    /// Seconds per 100 m → `m:ss`.
    private func pace100Label(_ secondsPer100: Double) -> String {
        let s = Int(secondsPer100.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // The HealthKit workout UUID, stripped of the source prefix.
    private var healthKitWorkoutID: String {
        if let raw = details["id"] as? String { return raw }
        return record.id.replacingOccurrences(of: "healthkit:", with: "")
    }

    // MARK: Debug export
    //
    // A full JSON dump of the stored record — both plan and completed sections,
    // the raw `details`, the parsed structure, the threshold snapshot the TSS was
    // scored against (as of the activity's own date), and a read-only re-run of
    // the scorer. Enough to reproduce/recheck the TSS + PMC algorithms offline.

    /// The Developer "Debug Mode" toggle, read live from `UserDefaults` (the same
    /// `debug_mode` key `AppSettings` persists) — gates the JSON export button.
    private var debugModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "debug_mode")
    }

    private func snapshotDict(_ s: PerformanceSnapshot) -> [String: Any] {
        var d: [String: Any] = [:]
        if let v = s.cyclingFTP {
            d["cycling_ftp_w"] = v
            d["cycling_ftp_is_estimated"] = s.cyclingFTPIsEstimated
        }
        if let v = s.runningFTP { d["running_ftp_w"] = v }
        if let v = s.cssPaceSeconds { d["css_pace_s_per_100m"] = v }
        if let v = s.lactateThrHR {
            d["lactate_thr_hr_bpm"] = v
            d["lactate_thr_hr_is_estimated"] = s.lactateThrHRIsEstimated
            d["lactate_thr_hr_confidence"] = s.lactateThrHRConfidence.rawValue
        }
        if let v = s.maxHR { d["max_hr_bpm"] = v }
        if let v = s.lactateThrPaceSeconds { d["lactate_thr_pace_s_per_km"] = v }
        if let v = s.vo2maxRunning { d["vo2max_running"] = v }
        if let v = s.vo2maxCycling { d["vo2max_cycling"] = v }
        if let v = s.weightKg { d["weight_kg"] = v }
        return d
    }

    private func exportDebugJSON() {
        Task { await buildAndExportDebugJSON() }
    }

    private func buildAndExportDebugJSON() async {
        let iso = ISO8601DateFormatter()
        var dump: [String: Any] = [
            "id": record.id,
            "source": record.source,
            "sport": record.sport,
            "name": record.name,
            "date": iso.string(from: record.date),
            "is_planned": record.isPlanned,
            "is_completed": record.isCompleted,
        ]
        if let minute = record.startMinute { dump["start_minute"] = minute }
        if !record.externalRefs.isEmpty { dump["external_refs"] = record.externalRefs }

        if record.isPlanned {
            var planned: [String: Any] = [
                "target_duration_minutes": record.targetDurationMinutes,
                "target_distance_meters": record.targetDistanceMeters,
                "notes": record.notes,
            ]
            if let tss = record.targetTSS { planned["target_tss"] = tss }
            if let pool = record.poolLengthMeters { planned["pool_length_meters"] = pool }
            if let steps = try? JSONSerialization.jsonObject(with: Data(record.stepsJSON.utf8)) {
                planned["steps"] = steps
            }
            dump["planned"] = planned
        }

        if record.isCompleted {
            var completed: [String: Any] = [
                "duration_minutes": record.durationMinutes,
                "distance_km": record.distanceKm,
            ]
            if let tss = record.tss { completed["tss"] = tss }
            dump["completed"] = completed
        }

        dump["details"] = details

        let snapshot = TrainingDataStore.shared.performanceHistory().snapshot(asOf: record.date)
        dump["performance_snapshot_asof"] = snapshotDict(snapshot)
        let recomputed = TSSCalculator.compute(details: details, snapshot: snapshot,
                                               heartRate: storedHeartRateSamples)
        var tssDump: [String: Any] = [:]
        if let value = recomputed.tss { tssDump["tss"] = value }
        if let basis = recomputed.basis?.label { tssDump["basis"] = basis }
        dump["recomputed_tss"] = tssDump

        // Live speed-stream provenance for a run — the exact (value, seconds) samples
        // the normalizer saw plus the staged result, recomputed for this workout from
        // either source so the algorithm can be rechecked offline (no log correlation).
        if family == .run {
            if isHealthKit,
               let diag = await HealthKitService.shared.speedStreamDiagnostics(forWorkoutID: healthKitWorkoutID) {
                dump["debug_speed_stream"] = diag
            } else if record.source == "garmin",
                      let diag = await GarminService.shared.speedStreamDiagnostics(activityId: TrainingDataStore.rawId(record.id)) {
                dump["debug_speed_stream"] = diag
            }
        }

        do {
            let data = try JSONSerialization.data(
                withJSONObject: dump, options: [.prettyPrinted, .sortedKeys])
            let filename = "workout_\(record.source)_\(Int(record.date.timeIntervalSince1970)).json"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try data.write(to: url)
            exportFile = ExportFile(url: url)
        } catch {
            actionError = error.localizedDescription
        }
    }

}

// MARK: - Export helpers
//
// Used by the training detail view's debug JSON export.

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
