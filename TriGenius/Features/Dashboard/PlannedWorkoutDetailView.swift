import SwiftUI

// MARK: - Planned Workout Detail View
//
// Per-planned-workout detail, the scheduled counterpart to `TrainingDetailView`.
// Shows the *target* of a not-yet-completed session (duration, TSS, time of day,
// notes) rather than achieved metrics. Reached by tapping a planned workout in
// the dashboard Agenda or the calendar's day detail / week view.

struct PlannedWorkoutDetailView: View {
    let initialWorkout: WorkoutRecord
    /// Live record, re-fetched on data changes so coach edits to the structure /
    /// targets appear without re-opening the screen (the handed-in record can be
    /// a stale snapshot once a sync replaces it). Falls back to `initialWorkout`.
    @State private var live: WorkoutRecord?
    @State private var editor: WorkoutEditorContext?
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    init(workout: WorkoutRecord) {
        self.initialWorkout = workout
    }

    private var workout: WorkoutRecord { live ?? initialWorkout }

    private var family: SportFamily { workout.family }
    private var isEstimatedTSS: Bool { workout.isEstimatedTSS }
    private var targetTSS: Double { workout.resolvedTargetTSS }
    private var structure: PlannedWorkoutStructure? { workout.structure }
    /// Planned distance, shown only for distance disciplines (run / swim). Prefixed
    /// with "~" unless the distance is exact (summed from distance-prescribed steps).
    private var distanceText: String? {
        guard family == .run || family == .swim,
              let distance = workout.plannedDistance, distance.meters > 0 else { return nil }
        let prefix = distance.source == .fixed ? "" : "~"
        return prefix + PlannedWorkoutFormat.distance(distance.meters)
    }
    /// Planned start time as "07:00", when a time-of-day was assigned.
    private var startTimeText: String? {
        guard let minute = workout.startMinute else { return nil }
        return String(format: "%d:%02d", minute / 60, minute % 60)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                header
                heroCapsule
                tssBasisNote
                if let structure, !structure.steps.isEmpty {
                    PlannedStructureCard(structure: structure, accent: family.color)
                }
                detailRows
                if !workout.notes.isEmpty {
                    notesCard
                }
            }
            .padding()
        }
        .navigationTitle(family.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editor = .edit(workout) }
            }
            ToolbarItem {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .sheet(item: $editor) { WorkoutEditorSheet(context: $0) }
        .confirmationDialog("Delete this planned workout?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await DataSyncCoordinator.shared.deletePlan(id: workout.id)
                    dismiss()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .trainingDataDidChange)) { _ in
            // Keep the last known record if the workout was deleted out from under us.
            if let fresh = TrainingDataStore.shared.scheduledWorkout(id: initialWorkout.id) {
                live = fresh
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: family.icon)
                .font(.title)
                .foregroundStyle(family.color)
                .frame(width: 52, height: 52)
                // Outlined, not filled — a planned session, not a completed one.
                .background(family.color.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m))
            VStack(alignment: .leading, spacing: 3) {
                Text(workout.name).font(.headline)
                HStack(spacing: 4) {
                    Text("Planned")
                    Text("·")
                    Text(workout.date, style: .date)
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if let intensity = workout.intensity {
                intensityBadge(intensity)
            }
        }
    }

    private func intensityBadge(_ category: IntensityCategory) -> some View {
        Text(category.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, 4)
            .background(category.color.opacity(0.18), in: Capsule())
            .foregroundStyle(category.color)
    }

    // MARK: Hero metrics — the planned duration + TSS target

    private struct HeroMetric: Identifiable {
        let id = UUID()
        let value: String
        let label: String
    }

    private var heroMetrics: [HeroMetric] {
        var metrics: [HeroMetric] = []
        // `plannedDurationMinutes` prefers the structure estimate, so mixed
        // time+distance sessions count the distance steps too. "~" only when the
        // session carries no explicit duration target (distance-prescribed).
        let planned = workout.plannedDurationMinutes
        if planned > 0 {
            let prefix = workout.targetDurationMinutes > 0 ? "" : "~"
            metrics.append(HeroMetric(value: prefix + durationHM(planned), label: "Duration"))
        }
        if let distanceText {
            metrics.append(HeroMetric(value: distanceText, label: "Distance"))
        }
        if targetTSS > 0 {
            metrics.append(HeroMetric(value: "\(Int(targetTSS.rounded()))", label: "TSS target"))
        }
        if metrics.isEmpty {
            metrics.append(HeroMetric(value: "—", label: "No target set"))
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

    // MARK: TSS provenance
    //
    // BUGS.md: surface where the planned TSS came from. A structured session gets
    // an intensity-based estimate from its steps; otherwise it's estimated from
    // duration × the discipline's typical intensity (see `PlannedTSS`).

    @ViewBuilder
    private var tssBasisNote: some View {
        if targetTSS > 0 {
            let basis = isEstimatedTSS
                ? "estimated from duration × typical intensity"
                : "computed from the planned structure & intensity targets"
            Label("TSS target \(basis)", systemImage: "function")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Spacing.xs)
        }
    }

    // MARK: Detail rows

    private struct DetailRow: Identifiable {
        let id = UUID()
        let label: String
        let value: String
        let icon: String
    }

    private var detailRowList: [DetailRow] {
        var rows: [DetailRow] = [
            .init(label: "Sport", value: family.displayName, icon: family.icon),
        ]
        if family == .swim, let pool = workout.poolLengthMeters, pool > 0 {
            rows.append(.init(label: "Pool", value: PlannedWorkoutFormat.distance(pool), icon: "ruler"))
        }
        rows.append(.init(label: "Date", value: workout.date.formatted(.dateTime.weekday(.wide).month().day()), icon: "calendar"))
        if let startTimeText {
            rows.append(.init(label: "Start time", value: startTimeText, icon: "clock"))
        } else if let segment = workout.startMinute.flatMap({ TimeOfDaySegment.containing(minute: $0) }) {
            rows.append(.init(label: "Time of day", value: segment.label, icon: "clock"))
        }
        if let context = weeklyContext {
            let percent = Int((context.tssShare * 100).rounded())
            rows.append(.init(label: "This week",
                              value: "Session \(context.index) of \(context.count) · \(percent)% load",
                              icon: "calendar.badge.clock"))
        }
        return rows
    }

    /// Where this session sits in its planned week: its order among the week's
    /// sessions and its share of the week's planned TSS. Nil for a lone session,
    /// where the context adds nothing.
    private var weeklyContext: (index: Int, count: Int, tssShare: Double)? {
        let cal = Calendar.current
        let weekStart = TrainingVolume.weekStart(of: workout.date, calendar: cal)
        guard let weekEnd = cal.date(byAdding: .day, value: 6, to: weekStart) else { return nil }
        let week = TrainingDataStore.shared.scheduledWorkouts(from: weekStart, to: weekEnd)
        guard week.count > 1 else { return nil }
        let ordered = week.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        guard let idx = ordered.firstIndex(where: { $0.id == workout.id }) else { return nil }
        let totalTSS = week.reduce(0.0) { $0 + $1.resolvedTargetTSS }
        let share = totalTSS > 0 ? workout.resolvedTargetTSS / totalTSS : 0
        return (idx + 1, week.count, share)
    }

    private var detailRows: some View {
        VStack(spacing: 0) {
            let rows = detailRowList
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

    // MARK: Notes

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Label("Notes", systemImage: "text.alignleft").font(.headline)
            Text(workout.notes)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}
