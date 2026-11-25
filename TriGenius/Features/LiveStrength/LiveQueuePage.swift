import SwiftUI
import TipKit

// MARK: - Live queue page
//
// The second page of a live session: the units already done, the unit being
// worked on (swap it, or push it to the end when its station is taken),
// everything still to do (drag to reorder, pull one forward, swap or delete it),
// and adding an exercise or ending the workout. All of it reshapes this session
// only — the plan stays as written.

struct LiveQueuePage: View {
    let session: StrengthSession

    private let live = LiveStrengthController.shared
    private let laterTip = LaterTip()
    @State private var swapping: LiveSwapTarget?
    @State private var adding = false
    @State private var confirmEnd = false

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    if session.units.contains(where: \.isFinished) { doneCard }
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
                Button("Add exercise") { adding = true }
                Button(role: .destructive) { confirmEnd = true } label: {
                    Text("End workout").foregroundStyle(Theme.Palette.danger)
                }
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .sheet(item: $swapping) { LiveSwapSheet(target: $0) }
        .sheet(isPresented: $adding) { LiveAddExerciseSheet(next: false) }
        .alert(endTitle, isPresented: $confirmEnd) {
            Button("End workout", role: .destructive) { live.update { s, now in s.end(at: now) } }
            Button("Cancel", role: .cancel) {}
        }
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
            if let set = session.draft {
                iconButton("Swap", systemImage: "arrow.left.arrow.right") { swapping = LiveSwapTarget(unit: unit.id, set: set) }
            }
            if !session.upcoming.isEmpty {
                iconButton("Later", systemImage: "arrow.down.to.line") {
                    laterTip.invalidate(reason: .actionPerformed)
                    live.update { s, _ in s.moveCurrentToEnd() }
                }
            }
        }
        .cardSurface(tint: .accentColor)
    }

    /// "Set 2 of 3 · 8 · BW · rest 0:45".
    private func nowLine(_ unit: StrengthSession.Unit) -> String {
        guard let set = session.draft, let position = session.currentSetPosition else { return "" }
        return (["Set \(position.number) of \(position.of)", LiveFormat.set(set)] + [LiveFormat.rest(set.rest)].compactMap { $0 })
            .joined(separator: " · ")
    }

    /// The finished units, greyed, with what was logged.
    private var doneCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Done").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(session.units.filter(\.isFinished).enumerated()), id: \.element.id) { offset, unit in
                    if offset > 0 { Divider().padding(.vertical, Theme.Spacing.m) }
                    HStack(spacing: Theme.Spacing.m) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Palette.success)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(unit.title).font(.headline)
                            Text(ExerciseSetsCard.volume(session.log.filter { $0.unit == unit.id }.map(\.set)))
                                .font(.subheadline)
                        }
                        .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
            }
            .cardSurface()
        }
    }

    private var upcomingCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Up next · hold to reorder or delete")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(session.upcoming.enumerated()), id: \.element.id) { offset, unit in
                    if offset > 0 { Divider().padding(.vertical, Theme.Spacing.m) }
                    upcomingRow(unit)
                        .draggable(String(unit.id))
                        .dropDestination(for: String.self) { ids, _ in move(ids, onto: offset) }
                        .contextMenu {
                            Button("Do now", systemImage: "arrow.up.to.line") { live.update { s, _ in s.doNow(unit: unit.id) } }
                            if let set = unit.current {
                                Button("Swap", systemImage: "arrow.left.arrow.right") { swapping = LiveSwapTarget(unit: unit.id, set: set) }
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) { live.update { s, _ in s.remove(unit: unit.id) } }
                        }
                }
            }
            .cardSurface()
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
            .tint(.primary)
            .buttonBorderShape(.circle)
    }

    private var endTitle: String {
        let left = session.totalSets - session.doneSets
        return left > 0 ? "End the workout with \(left) set\(left == 1 ? "" : "s") left?" : "End the workout?"
    }
}

/// Picks exercises and adds them, with their sets, to the session — after
/// everything still to do, or `next`. Opens on the picker; each picked exercise
/// is then a row of the workout editor's, adjustable before adding.
struct LiveAddExerciseSheet: View {
    let next: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var steps: [StepDraft] = []
    @State private var picking = true
    @State private var replacing: UUID?
    @State private var expanded: UUID?

    var body: some View {
        NavigationStack {
            Form {
                ForEach($steps) { $step in
                    ExerciseEditorRow(step: $step,
                                      isExpanded: Binding(get: { expanded == step.id }, set: { expanded = $0 ? step.id : nil }),
                                      pausesAfter: true) {
                        replacing = step.id
                        picking = true
                    }
                }
                .onDelete { steps.remove(atOffsets: $0) }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Exercises")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", role: .confirm) {
                        let units = StrengthSession.units(planned: steps.map { $0.dict(swim: false) })
                        // Each `next` insert lands before the last, so they go in reversed.
                        LiveStrengthController.shared.update { s, _ in
                            for unit in next ? units.reversed() : units { s.add(sets: unit.sets, next: next) }
                        }
                        dismiss()
                    }
                    .disabled(steps.isEmpty)
                }
            }
            .exercisePicker(isPresented: $picking, multiple: replacing == nil) { choices in
                if let replacing, let choice = choices.first {
                    steps.update(id: replacing) { $0.choose(choice) }
                } else {
                    steps += choices.map(StepDraft.exercise)
                    if steps.count == 1 { expanded = steps.first?.id }
                }
            }
            .onChange(of: picking) {
                guard !picking else { return }
                replacing = nil
                if steps.isEmpty { dismiss() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
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
