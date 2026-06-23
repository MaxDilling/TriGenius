import SwiftUI

// MARK: - Planned Workout Detail View
//
// Per-planned-workout detail, the scheduled counterpart to `TrainingDetailView`.
// Shows the *target* of a not-yet-completed session (duration, TSS, time of day,
// notes) rather than achieved metrics. Reached by tapping a planned workout in
// the dashboard Agenda or the calendar's day detail / week view.

struct PlannedWorkoutDetailView: View {
    let workout: ScheduledWorkoutRecord

    private var family: SportFamily { workout.family }
    private var isEstimatedTSS: Bool { workout.isEstimatedTSS }
    private var targetTSS: Double { workout.resolvedTargetTSS }
    private var structure: PlannedWorkoutStructure? { workout.structure }
    /// Estimated total distance, shown only for distance disciplines (run / swim).
    private var distanceText: String? {
        guard family == .run || family == .swim,
              let meters = structure?.totalDistanceMeters, meters > 0 else { return nil }
        return "~" + PlannedWorkoutFormat.distance(meters)
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
                if let structure, !structure.steps.isEmpty {
                    structureCard(structure)
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
        if workout.targetDurationMinutes > 0 {
            metrics.append(HeroMetric(value: durationHM(workout.targetDurationMinutes), label: "Duration"))
        }
        if let distanceText {
            metrics.append(HeroMetric(value: distanceText, label: "Distance"))
        }
        if targetTSS > 0 {
            metrics.append(HeroMetric(value: "\(isEstimatedTSS ? "~" : "")\(Int(targetTSS.rounded()))", label: "TSS target"))
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
            .init(label: "Date", value: workout.date.formatted(.dateTime.weekday(.wide).month().day()), icon: "calendar"),
        ]
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
        if isEstimatedTSS, targetTSS > 0 {
            rows.append(.init(label: "TSS", value: "estimated from duration", icon: "wand.and.stars"))
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

    // MARK: Structure — the step-by-step breakdown of the session

    private func structureCard(_ structure: PlannedWorkoutStructure) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Label("Structure", systemImage: "list.bullet.indent").font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(structure.steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 { Divider() }
                    stepRow(step, structure: structure)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    @ViewBuilder
    private func stepRow(_ step: PlannedDisplayStep, structure: PlannedWorkoutStructure) -> some View {
        if step.isGroup {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: 6) {
                    Image(systemName: "repeat")
                        .font(.caption.weight(.semibold)).foregroundStyle(family.color)
                    Text("\(step.repeatCount)×").font(.subheadline.weight(.semibold))
                    Spacer()
                }
                ForEach(step.steps) { leaf in
                    leafRow(leaf, structure: structure)
                        .padding(.leading, Theme.Spacing.l)
                }
            }
            .padding(.vertical, Theme.Spacing.s)
        } else if let leaf = step.leaf {
            leafRow(leaf, structure: structure)
                .padding(.vertical, Theme.Spacing.s)
        }
    }

    private func leafRow(_ leaf: PlannedStepLeaf, structure: PlannedWorkoutStructure) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: leaf.icon)
                .font(.caption).foregroundStyle(family.color)
                .frame(width: 20)
            Text(leaf.typeLabel).font(.subheadline)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(PlannedWorkoutFormat.extent(leaf))
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                if let target = structure.targetText(leaf) {
                    Text(target).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
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
