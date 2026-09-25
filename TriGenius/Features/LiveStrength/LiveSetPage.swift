import SwiftUI

// MARK: - Live set page
//
// The first page of a live session: the current set — prescription, adjustable
// reps/time and load, what was lifted last time — or, after a logged set, its
// rest with what comes next and the optional "how hard" rating. The exercise
// demo and form cues are placeholders until the library carries media.

struct LiveSetPage: View {
    let session: StrengthSession

    private let live = LiveStrengthController.shared
    @ScaledMetric(relativeTo: .largeTitle) private var valueSize = 40
    @ScaledMetric(relativeTo: .largeTitle) private var timerSize = 72
    @State private var swapping: LiveSwapTarget?
    @State private var editingLast = false

    private static let weightStep = 2.5
    private static let holdStep: Double = 5

    var body: some View {
        Group {
            if case .resting(let since, let until) = session.phase(at: .now) {
                rest(since: since, until: until)
            } else if let index = session.currentIndex, let set = session.draft {
                work(unit: session.units[index], set: set)
            }
        }
        .sheet(item: $swapping) { LiveSwapSheet(target: $0) }
        .sheet(isPresented: $editingLast) {
            if let last = session.log.last?.set { LiveEditSetSheet(set: last) }
        }
    }

    // MARK: Set

    private func work(unit: StrengthSession.Unit, set: StrengthSets.SetRow) -> some View {
        VStack(spacing: Theme.Spacing.m) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    LiveProgressBar(session: session)
                    HStack {
                        Text("Exercise \((session.currentIndex ?? 0) + 1) of \(session.units.count)")
                        Spacer()
                        if let position = session.currentSetPosition { Text("Set \(position.number) of \(position.of)") }
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    Text(set.title).font(.largeTitle.bold())
                    HStack(spacing: Theme.Spacing.s) {
                        setChips(unit: unit, set: set)
                        Spacer(minLength: 0)
                        Button("Swap", systemImage: "arrow.left.arrow.right") {
                            swapping = LiveSwapTarget(unit: unit.id, set: set)
                        }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                    }
                    demoCard
                    prescription(set)
                }
                .padding(.horizontal)
            }
            Text(nextLine(unit: unit, set: set)).font(.subheadline).foregroundStyle(.secondary)
            primaryButton(set)
        }
    }

    private func setChips(unit: StrengthSession.Unit, set: StrengthSets.SetRow) -> some View {
        let indices = unit.sets.indices.filter { unit.sets[$0].sameExercise(as: set) }
        return ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(Array(indices.enumerated()), id: \.offset) { number, index in
                    let done = index < unit.done
                    let color: Color = done ? Theme.Palette.success : index == unit.done ? .accentColor : .secondary
                    Label("Set \(number + 1)", systemImage: "checkmark")
                        .labelStyle(ChipLabelStyle(showsIcon: done))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, Theme.Spacing.m)
                        .padding(.vertical, Theme.Spacing.xs + 2)
                        .background(color.opacity(0.18), in: Capsule())
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var demoCard: some View {
        VStack(spacing: 0) {
            VStack(spacing: Theme.Spacing.s) {
                Image(systemName: "play.circle").font(.largeTitle)
                Text("Exercise demo")
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 140)
            Divider()
            Text("Form cues will appear here.")
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.m)
        }
        .background(Color.appSecondaryBackground, in: .rect(cornerRadius: Theme.Radius.l, style: .continuous))
    }

    private func prescription(_ set: StrengthSets.SetRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if set.reps == nil, let target = set.seconds {
                if case .holding(let since) = session.phase {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        stepperRow("Hold", value: LiveFormat.clock(target - (session.pausedAt ?? context.date).timeIntervalSince(since)))
                    }
                } else {
                    stepperRow("Time", value: LiveFormat.clock(target), canDecrease: target > Self.holdStep) { delta in
                        edit { $0.seconds = max(Self.holdStep, target + delta * Self.holdStep) }
                    }
                }
            } else {
                stepperRow("Reps", value: "\(set.reps ?? 0)", canDecrease: (set.reps ?? 0) > 0) { delta in
                    edit { $0.reps = max(0, ($0.reps ?? 0) + Int(delta)) }
                }
            }
            Divider()
            stepperRow("Load", value: LiveFormat.load(set.weightKg), canDecrease: set.weightKg != nil) { delta in
                edit {
                    let kg = ($0.weightKg ?? 0) + delta * Self.weightStep
                    $0.weightKg = kg > 0 ? kg : nil
                }
            }
            let last = live.lastLifted(set)
            if !last.isEmpty {
                Text("Last session: \(ExerciseSetsCard.volume(last))")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.top, Theme.Spacing.s)
            }
        }
        .cardSurface(cornerRadius: Theme.Radius.l, padding: Theme.Spacing.l)
    }

    /// A value with − / + beside it; `step` gets −1 or +1. Without `step` it is
    /// a read-out only.
    private func stepperRow(_ title: String, value: String, canDecrease: Bool = true,
                            step: ((Double) -> Void)? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: valueSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer()
            if let step {
                roundButton("minus", label: "Decrease \(title.lowercased())") { step(-1) }.disabled(!canDecrease)
                roundButton("plus", label: "Increase \(title.lowercased())") { step(1) }
            }
        }
        .padding(.vertical, Theme.Spacing.s)
    }

    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title3.weight(.semibold)).frame(width: 36, height: 36)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }

    private func edit(_ change: @escaping (inout StrengthSets.SetRow) -> Void) {
        live.update { s, _ in
            guard var set = s.draft else { return }
            change(&set)
            s.edit(set)
        }
    }

    /// "Next: rest 0:45 · then set 3", "Next: Plank", "Last set of the workout".
    private func nextLine(unit: StrengthSession.Unit, set: StrengthSets.SetRow) -> String {
        let following = unit.sets.indices.contains(unit.done + 1) ? unit.sets[unit.done + 1] : session.upcoming.first?.current
        guard let following else { return "Last set of the workout" }
        let then = following.sameExercise(as: set)
            ? "set \((session.currentSetPosition?.number ?? 0) + 1)"
            : following.title
        guard let rest = LiveFormat.rest(set.rest) else { return "Next: \(then)" }
        return "Next: \(rest) · then \(then)"
    }

    @ViewBuilder
    private func primaryButton(_ set: StrengthSets.SetRow) -> some View {
        let isHold = set.reps == nil && set.seconds != nil
        Group {
            if case .holding(let since) = session.phase {
                bigButton("Done", systemImage: "checkmark") {
                    live.update { s, now in
                        guard var held = s.draft else { return }
                        held.seconds = now.timeIntervalSince(since).rounded()
                        s.complete(held, at: now)
                    }
                }
            } else if isHold {
                bigButton("Start hold", systemImage: "play.fill") { live.update { s, now in s.startHold(at: now) } }
            } else {
                bigButton("Set done", systemImage: "checkmark") {
                    live.update { s, now in if let set = s.draft { s.complete(set, at: now) } }
                }
            }
        }
        .disabled(session.pausedAt != nil)
    }

    private func bigButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.extraLarge)
        .padding(.horizontal)
    }

    // MARK: Rest

    private func rest(since: Date, until: Date?) -> some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.l) {
                LiveProgressBar(session: session)
                if let last = session.log.last { loggedCard(last) }
                restRing(since: since, until: until)
                restButtons(timed: until != nil)
                upNextCard
            }
            .padding(.horizontal)
        }
    }

    private func loggedCard(_ last: StrengthSession.Logged) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "checkmark")
                .font(.headline)
                .foregroundStyle(Theme.Palette.success)
                .frame(width: 40, height: 40)
                .background(Theme.Palette.success.opacity(0.18), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Set \(loggedNumber(last)) logged").font(.headline)
                Text(LiveFormat.set(last.set)).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit") { editingLast = true }
                .buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
        .cardSurface(cornerRadius: Theme.Radius.l)
    }

    /// The logged set's number within its exercise in its unit.
    private func loggedNumber(_ last: StrengthSession.Logged) -> Int {
        session.log.filter { $0.unit == last.unit && $0.set.sameExercise(as: last.set) }.count
    }

    private func restRing(since: Date, until: Date?) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = session.pausedAt ?? context.date
            let total = until.map { $0.timeIntervalSince(since) }
            let shown = until.map { $0.timeIntervalSince(now) } ?? now.timeIntervalSince(since)
            ZStack {
                Circle().stroke(Color.appTertiaryBackground, lineWidth: 14)
                if let total, total > 0 {
                    Circle()
                        .trim(from: 0, to: max(0, shown / total))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: shown)
                }
                VStack(spacing: Theme.Spacing.xs) {
                    Text("Rest").font(.title3).foregroundStyle(.secondary)
                    Text(LiveFormat.clock(shown))
                        .font(.system(size: timerSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: until != nil))
                    Text(total.map { "of \(LiveFormat.clock($0))" } ?? "until you're ready")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 280)
        .aspectRatio(1, contentMode: .fit)
        .padding(.vertical, Theme.Spacing.s)
    }

    private func restButtons(timed: Bool) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            if timed {
                Button("−15 s") { live.update { s, now in s.adjustRest(by: -15, at: now) } }
                Button("+15 s") { live.update { s, now in s.adjustRest(by: 15, at: now) } }
                Button("Skip rest", systemImage: "forward.end") { live.update { s, now in s.skipRest(at: now) } }
            } else {
                Button("Start next set", systemImage: "forward.end") { live.update { s, now in s.skipRest(at: now) } }
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(session.pausedAt != nil)
    }

    @ViewBuilder
    private var upNextCard: some View {
        if let next = session.draft, let position = session.currentSetPosition, let last = session.log.last {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Up next").font(.caption).foregroundStyle(.secondary)
                        Text("\(next.title) · set \(position.number) of \(position.of)").font(.headline)
                    }
                    Spacer()
                    Text(LiveFormat.set(next)).font(.title3.bold()).monospacedDigit()
                }
                Divider()
                HStack(spacing: Theme.Spacing.s) {
                    Text("How hard was set \(loggedNumber(last))?")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    ForEach(StrengthSets.Effort.allCases, id: \.self) { effort in
                        let selected = last.set.effort == effort
                        Button {
                            live.update { s, _ in s.rateLast(selected ? nil : effort) }
                        } label: {
                            Text(effort.rawValue.capitalized)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, Theme.Spacing.m)
                                .padding(.vertical, Theme.Spacing.s)
                                .foregroundStyle(selected ? Color.white : Color.primary)
                                .background(selected ? Color.accentColor : Color.appTertiaryBackground, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            .cardSurface(cornerRadius: Theme.Radius.l, padding: Theme.Spacing.l)
        }
    }
}

/// A set chip's label: the checkmark only once the set is done.
private struct ChipLabelStyle: LabelStyle {
    let showsIcon: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            configuration.title
            if showsIcon { configuration.icon }
        }
    }
}

// MARK: - Edit the last logged set

struct LiveEditSetSheet: View {
    @State var set: StrengthSets.SetRow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if set.reps != nil || set.seconds == nil {
                    Stepper("Reps: \(set.reps ?? 0)", value: Binding(get: { set.reps ?? 0 }, set: { set.reps = $0 }), in: 0...100)
                } else {
                    Stepper("Time: \(ExerciseSetsCard.time(set.seconds))",
                            value: Binding(get: { set.seconds ?? 0 }, set: { set.seconds = $0 }), in: 0...600, step: 5)
                }
                Stepper("Load: \(LiveFormat.load(set.weightKg))",
                        value: Binding(get: { set.weightKg ?? 0 }, set: { set.weightKg = $0 > 0 ? $0 : nil }),
                        in: 0...500, step: 2.5)
            }
            .navigationTitle("Edit set")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        LiveStrengthController.shared.update { s, _ in
                            s.editLast(reps: set.reps, seconds: set.seconds, weightKg: set.weightKg)
                        }
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
