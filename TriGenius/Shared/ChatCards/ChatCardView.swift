import SwiftUI

// MARK: - Chat card views
//
// Renders a `ChatCard` inside a coach chat reply. Workout cards fetch their
// live record by id (re-fetching on data changes), so the card always shows
// the store's current state; a tap pushes the full detail view via
// `ChatCardDestination` on the chat's NavigationStack. Chart cards live in
// `ChartChatCards.swift`.

struct ChatCardView: View {
    let card: ChatCard

    var body: some View {
        switch card {
        case .workout(let id, let caption):
            WorkoutChatCard(id: id, caption: caption)
        case .workoutDiff(let id, let name, let caption, let changes):
            WorkoutChatCard(id: id, caption: caption, fallbackName: name, changes: changes)
        case .workoutDeleted(let name, let sport, let date):
            DeletedWorkoutCard(name: name, sport: sport, date: date)
        case .metric(let key, let months):
            MetricChatCard(key: key, months: months)
        case .ctlTrend:
            CTLTrendChatCard()
        case .rampRate(let weeks):
            RampRateChatCard(weeks: weeks)
        case .sportShare(let metric, let weeks):
            SportShareChatCard(metric: metric, weeks: weeks)
        case .zones(let sport, let weeks):
            ZonesChatCard(sport: sport, weeks: weeks)
        }
    }
}

// MARK: - Workout card

/// Compact tappable workout row: sport badge, caption/title/summary, trailing
/// date — plus the change lines when the card reports a modification. Shows a
/// visible "no longer available" state when the record has since vanished.
private struct WorkoutChatCard: View {
    let id: String
    var caption: String? = nil
    var fallbackName: String? = nil
    var changes: [String] = []

    @State private var workout: WorkoutRecord?
    @State private var loaded = false

    var body: some View {
        Group {
            if workout != nil {
                NavigationLink(value: ChatCardDestination.workout(id: id)) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .trainingDataDidChange)) { _ in reload() }
    }

    private func reload() {
        let store = TrainingDataStore.shared
        workout = store.activity(id: id) ?? store.scheduledWorkout(id: id)
        loaded = true
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.m) {
                SportBadge(family: workout?.family ?? .other, missing: workout == nil && loaded)

                VStack(alignment: .leading, spacing: 2) {
                    if let caption {
                        Text(caption.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(workout?.name ?? fallbackName ?? "Workout")
                        .font(.headline).lineLimit(1)
                    Text(summary).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)

                if let workout {
                    if workout.isCompleted {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    dateColumn(workout.date)
                }
            }
            if !changes.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                        Text(change).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 44 + Theme.Spacing.m)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .coachAccent()
        .contentShape(.rect)
    }

    private var summary: String {
        guard let workout else { return "Workout no longer available" }
        if workout.isCompleted {
            var parts: [String] = []
            if let tss = workout.tss, tss > 0 { parts.append("\(Int(tss.rounded())) TSS") }
            parts.append(durationHM(workout.durationMinutes))
            return parts.joined(separator: "  •  ")
        }
        return workout.plannedSummaryLine()
    }

    private func dateColumn(_ date: Date) -> some View {
        VStack(spacing: 2) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.caption2).foregroundStyle(.secondary)
            Text(date.formatted(.dateTime.day()))
                .font(.title3.bold())
        }
    }
}

// MARK: - Deleted-workout card

private struct DeletedWorkoutCard: View {
    let name: String
    let sport: String
    let date: Date

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            SportBadge(family: SportFamily(sportKey: sport), missing: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("DELETED")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.Palette.danger)
                Text(name)
                    .font(.headline).lineLimit(1)
                    .strikethrough()
                    .foregroundStyle(.secondary)
                Text(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .coachAccent()
    }
}

// MARK: - Shared pieces

private struct SportBadge: View {
    let family: SportFamily
    var missing = false

    var body: some View {
        ZStack {
            Circle().fill((missing ? Color.secondary : family.color).opacity(0.25))
            Image(systemName: missing ? "calendar.badge.minus" : family.icon)
                .font(.headline)
                .foregroundStyle(missing ? Color.secondary : family.color)
        }
        .frame(width: 44, height: 44)
    }
}
