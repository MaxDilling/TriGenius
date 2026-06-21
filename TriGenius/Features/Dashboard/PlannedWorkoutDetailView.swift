import SwiftUI

// MARK: - Planned Workout Detail View
//
// Per-planned-workout detail, the scheduled counterpart to `TrainingDetailView`.
// Shows the *target* of a not-yet-completed session (duration, TSS, time of day,
// notes) rather than achieved metrics. Reached by tapping a planned workout in
// the dashboard Agenda or the calendar's day detail / week view.

struct PlannedWorkoutDetailView: View {
    let workout: ScheduledWorkoutRecord

    private var family: SportFamily { SportFamily(sportKey: workout.sport) }
    private var isEstimatedTSS: Bool { workout.targetTSS == nil }
    private var targetTSS: Double {
        workout.targetTSS ?? WeeklyTargets.estimatedTSS(family: family, minutes: workout.targetDurationMinutes)
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
        }
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
        if isEstimatedTSS, targetTSS > 0 {
            rows.append(.init(label: "TSS", value: "estimated from duration", icon: "wand.and.stars"))
        }
        return rows
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
