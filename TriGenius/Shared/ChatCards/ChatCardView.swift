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
        case .workout(let id, let caption, let undo):
            WorkoutChatCard(id: id, caption: caption, undo: undo)
        case .workoutDiff(let id, let name, let caption, let changes, let undo):
            WorkoutChatCard(id: id, caption: caption, fallbackName: name, changes: changes, undo: undo)
        case .workoutDeleted(let name, let sport, let date, let undo):
            DeletedWorkoutCard(name: name, sport: sport, date: date, undo: undo)
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
    var undo: ChatCard.PlanUndo? = nil

    @State private var workout: WorkoutRecord?
    @State private var loaded = false

    // Undo sits beside the link, never inside its label: a button nested in a
    // NavigationLink swallows the link's tap.
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if workout != nil {
                NavigationLink(value: ChatCardDestination.workout(id: id)) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
            if let undo {
                UndoPlanChange(undo: undo).padding(.leading, 44 + Theme.Spacing.m)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .coachAccent()
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
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Palette.success)
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
            if let workout, !workout.isCompleted {
                let blocks = StrengthSets.blocks(planned: WorkoutPayloadBuilder.parseSteps(workout.stepsJSON) ?? [])
                if !blocks.isEmpty {
                    ExerciseLines(blocks: blocks).padding(.leading, 44 + Theme.Spacing.m)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    var undo: ChatCard.PlanUndo? = nil

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
            if let undo { UndoPlanChange(undo: undo) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .coachAccent()
    }
}

// MARK: - Strength exercises
//
// What the coach put into a strength plan, one line per exercise ("Back squat ·
// 3 × 5 @ 60 kg"), so the athlete reads the session without opening it. The
// full set table is one tap away on the detail.

private struct ExerciseLines: View {
    let blocks: [StrengthSets.Block]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.rounds > 1 {
                    Label("\(block.rounds)× circuit", systemImage: "repeat").font(.caption.weight(.semibold))
                }
                ForEach(Array(block.items.enumerated()), id: \.offset) { _, item in
                    Text(Self.line(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, block.rounds > 1 ? Theme.Spacing.m : 0)
                }
            }
        }
    }

    /// "3 × 10 @ 20 kg" for uniform sets, "10 / 8 / 8" when the reps vary; the
    /// weight only when every set carries the same one.
    private static func line(_ item: StrengthSets.Item) -> String {
        guard case .exercise(let lines) = item, let first = lines.first else {
            if case .rest(let rest) = item { return ExerciseSetsCard.restLabel(rest) }
            return ""
        }
        let sets = lines.compactMap(\.set)
        let extents = sets.map { $0.reps.map(String.init) ?? ExerciseSetsCard.time($0.seconds) }
        let volume = Set(extents).count == 1 ? "\(sets.count) × \(extents[0])" : extents.joined(separator: " / ")
        let loads = Set(sets.map(ExerciseSetsCard.load))
        let load = loads.count == 1 ? loads.first.map { $0 == "BW" ? " · BW" : " @ \($0) kg" } ?? "" : ""
        return "\(first.title) · \(volume)\(load)"
    }
}

// MARK: - Undo
//
// Every coach-made plan change can be taken back from the card that reports it
// — the change went in without being asked, so reversing it must be one tap.
// The affordance lives only in the session that made it (`ChatCard.PlanUndo`
// isn't persisted), and states plainly when the plan it would act on is gone.

private struct UndoPlanChange: View {
    let undo: ChatCard.PlanUndo

    @State private var state: State = .offered
    private enum State { case offered, working, undone, gone }

    var body: some View {
        switch state {
        case .offered:
            Button("Undo") {
                state = .working
                Task {
                    let ok = await DataSyncCoordinator.shared.applyUndo(undo)
                    state = ok ? .undone : .gone
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        case .working:
            ProgressView().controlSize(.mini)
        case .undone:
            Label("Undone", systemImage: "arrow.uturn.backward")
                .font(.caption).foregroundStyle(.secondary)
        case .gone:
            Text("That workout has changed since — nothing to undo.")
                .font(.caption).foregroundStyle(.secondary)
        }
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
