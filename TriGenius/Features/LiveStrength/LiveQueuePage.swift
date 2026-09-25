import SwiftUI
import TipKit

// MARK: - Live queue page
//
// The second page of a live session: the unit being worked on (push it to the
// end when its station is taken), everything still to do (drag to reorder, pull
// one forward, swap it), and adding an exercise or ending the workout. All of it
// reshapes this session only — the plan stays as written.

struct LiveQueuePage: View {
    let session: StrengthSession

    private let live = LiveStrengthController.shared
    private let laterTip = LaterTip()
    @State private var swapping: LiveSwapTarget?
    @State private var adding = false
    @State private var newExercise = StepDraft.exercise()
    @State private var confirmEnd = false

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    header
                    if let index = session.currentIndex { nowCard(session.units[index]) }
                    if !session.upcoming.isEmpty {
                        TipView(laterTip)
                            .tipBackground(Color.appSecondaryBackground)
                            .tipCornerRadius(Theme.Radius.l)
                        upcomingCard
                    }
                }
                .padding(.horizontal)
            }
            HStack(spacing: Theme.Spacing.m) {
                Button("Add exercise") {
                    newExercise = .exercise()
                    adding = true
                }
                Button("End workout", role: .destructive) { confirmEnd = true }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .sheet(item: $swapping) { LiveSwapSheet(target: $0) }
        .sheet(isPresented: $adding) {
            NavigationStack {
                StepEditorView(step: $newExercise, sport: .strength, allowRepeat: false, picking: true)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(role: .close) { adding = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Add", role: .confirm) {
                                let sets = StrengthSession.units(planned: [newExercise.dict(swim: false)]).first?.sets ?? []
                                live.update { s, _ in s.append(sets: sets) }
                                adding = false
                            }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 560)
            #endif
        }
        .alert(endTitle, isPresented: $confirmEnd) {
            Button("End workout", role: .destructive) { live.update { s, now in s.end(at: now) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(session.planName).font(.title2.bold())
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(progressLine(at: context.date)).font(.subheadline).foregroundStyle(.secondary)
            }
            LiveProgressBar(session: session)
        }
        .padding(.vertical, Theme.Spacing.s)
    }

    /// "1 of 9 sets · ~6 min left" — the time only while the plan's duration
    /// still has some left.
    private func progressLine(at now: Date) -> String {
        let sets = "\(session.doneSets) of \(session.totalSets) sets"
        let left = session.plannedMinutes - session.elapsed(at: now) / 60
        return left >= 1 ? "\(sets) · ~\(Int(left.rounded())) min left" : sets
    }

    private func nowCard(_ unit: StrengthSession.Unit) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text(unit.title).font(.headline)
                HStack(spacing: Theme.Spacing.s) {
                    HStack(spacing: 3) {
                        ForEach(unit.sets.indices, id: \.self) { index in
                            Capsule()
                                .fill(index < unit.done ? Theme.Palette.success
                                      : index == unit.done ? Color.accentColor : Color.appTertiaryBackground)
                                .frame(width: 14, height: 5)
                        }
                    }
                    .accessibilityHidden(true)
                    Text(nowLine(unit)).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text("Now")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, Theme.Spacing.s)
                .padding(.vertical, Theme.Spacing.xs)
                .background(Color.accentColor.opacity(0.18), in: Capsule())
            if !session.upcoming.isEmpty {
                iconButton("Later", systemImage: "arrow.down.to.line") {
                    laterTip.invalidate(reason: .actionPerformed)
                    live.update { s, _ in s.moveCurrentToEnd() }
                }
            }
        }
        .cardSurface(cornerRadius: Theme.Radius.l, padding: Theme.Spacing.l)
    }

    /// "Set 2 of 3 · 8 · BW · rest 0:45".
    private func nowLine(_ unit: StrengthSession.Unit) -> String {
        guard let set = session.draft, let position = session.currentSetPosition else { return "" }
        return (["Set \(position.number) of \(position.of)", LiveFormat.set(set)] + [LiveFormat.rest(set.rest)].compactMap { $0 })
            .joined(separator: " · ")
    }

    private var upcomingCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Up next · hold and drag to reorder")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(session.upcoming.enumerated()), id: \.element.id) { offset, unit in
                    if offset > 0 { Divider().padding(.vertical, Theme.Spacing.m) }
                    upcomingRow(unit)
                        .draggable(String(unit.id))
                        .dropDestination(for: String.self) { ids, _ in move(ids, onto: offset) }
                }
            }
            .cardSurface(cornerRadius: Theme.Radius.l, padding: Theme.Spacing.l)
        }
    }

    private func upcomingRow(_ unit: StrengthSession.Unit) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(unit.title).font(.headline)
                Text(ExerciseSetsCard.volume(Array(unit.sets[unit.done...])))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            iconButton("Do now", systemImage: "arrow.up.to.line") { live.update { s, _ in s.doNow(unit: unit.id) } }
            if let set = unit.current {
                iconButton("Swap", systemImage: "arrow.left.arrow.right") { swapping = LiveSwapTarget(unit: unit.id, set: set) }
            }
        }
        .contentShape(Rectangle())
    }

    /// Moves the dropped upcoming unit into the slot of the one at `target`.
    private func move(_ ids: [String], onto target: Int) {
        guard let id = ids.first.flatMap(Int.init),
              let from = session.upcoming.firstIndex(where: { $0.id == id }), from != target else { return }
        live.update { s, _ in s.moveUpcoming(from: [from], to: target > from ? target + 1 : target) }
    }

    private func iconButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
    }

    private var endTitle: String {
        let left = session.totalSets - session.doneSets
        return left > 0 ? "End the workout with \(left) set\(left == 1 ? "" : "s") left?" : "End the workout?"
    }
}

/// Introduces "Later" once: dismissed, or gone the first time it is used.
private struct LaterTip: Tip {
    var title: Text { Text("Station taken?") }
    var message: Text? {
        Text("Tap \(Image(systemName: "arrow.down.to.line")) to move the current exercise to the end and start the next one.")
    }
    var image: Image? { Image(systemName: "clock") }
}
