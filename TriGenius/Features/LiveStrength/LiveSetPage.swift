import SwiftUI

// MARK: - Live set page
//
// The first page of a live session: the current set — prescription, adjustable
// reps/time and load, what was lifted last time — or, after a logged set, its
// rest: the set just logged with the optional "how hard" rating, the timer, and
// what comes next — after an exercise's last set, also one more set or another
// exercise first, and after the workout's last set its end. An exercise with a
// pose shows its animation above the prescription; one without shows nothing.

struct LiveSetPage: View {
    let session: StrengthSession

    private let live = LiveStrengthController.shared
    @ScaledMetric(relativeTo: .largeTitle) private var valueSize = 40
    @ScaledMetric(relativeTo: .largeTitle) private var timerSize = 72
    @State private var editingLast = false
    @State private var addingExercise = false

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
        .sheet(isPresented: $editingLast) {
            if let last = session.log.last?.set { LiveEditSetSheet(set: last) }
        }
        .sheet(isPresented: $addingExercise) { LiveAddExerciseSheet(next: true) }
    }

    // MARK: Set

    private func work(unit: StrengthSession.Unit, set: StrengthSets.SetRow) -> some View {
        VStack(spacing: Theme.Spacing.m) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    Text(set.title).font(.largeTitle.bold())
                    if let animation = set.exerciseId.flatMap(ExerciseLibrary.find(id:)).flatMap(ExerciseAnimation.init(exercise:)) {
                        animation
                            .frame(height: 220)
                            .contentCard(padding: Theme.Spacing.s)
                    }
                    prescription(set)
                }
                .padding(.horizontal)
            }
            Text(nextLine(unit: unit, set: set)).font(.subheadline).foregroundStyle(.secondary)
            continueButton()
        }
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
        .cardSurface()
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
        .tint(.primary)
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

    /// The session's next step, the same one the Live Activity's button takes.
    private func continueButton(exerciseDone: Bool = false) -> some View {
        let step = session.nextStep(at: .now)
        let title = switch step {
        case .resume: "Resume"
        case .logSet: "Set done"
        case .startHold: "Start hold"
        case .endHold: "Done"
        case .nextSet: exerciseDone ? "Start next exercise" : "Start next set"
        case .finish: "End workout"
        }
        return bigButton(title, systemImage: step.symbol) { live.update { s, now in s.advance(step, at: now) } }
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
        let last = session.log.last
        let nextUnit = session.currentIndex.map { session.units[$0].id }
        let exerciseDone = last.map { $0.unit != nextUnit } ?? false
        return VStack(spacing: Theme.Spacing.m) {
            if let last { loggedCard(last).padding(.horizontal) }
            Spacer(minLength: 0)
            if session.isComplete {
                allDone
            } else {
                restRing(since: since, until: until)
                if until != nil { adjustButtons }
            }
            Spacer(minLength: 0)
            upNext
            if exerciseDone {
                HStack(spacing: Theme.Spacing.s) {
                    Button("Set", systemImage: "plus") { live.update { s, _ in s.oneMoreSet() } }
                        .accessibilityLabel("One more set")
                    Button("Exercise", systemImage: "plus") { addingExercise = true }
                        .accessibilityLabel("Add exercise")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .disabled(session.pausedAt != nil)
                .padding(.bottom, Theme.Spacing.s)
            }
            continueButton(exerciseDone: exerciseDone)
        }
    }

    /// The set just logged, editable, with the optional "how hard" rating.
    private func loggedCard(_ last: StrengthSession.Logged) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
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
                    .buttonStyle(.bordered).tint(.primary).buttonBorderShape(.capsule)
            }
            Divider()
            HStack(spacing: Theme.Spacing.s) {
                Text("How hard was it?").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
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
        .cardSurface()
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
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .contentTransition(.numericText(countsDown: until != nil))
                    Text(total.map { "of \(LiveFormat.clock($0))" } ?? "until you're ready")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(Theme.Spacing.xl)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 280, maxHeight: 280)
        .padding(.top, Theme.Spacing.s)
    }

    private var adjustButtons: some View {
        HStack {
            adjustButton("−15", label: "Shorten rest by 15 seconds", by: -15)
            Spacer()
            adjustButton("+15", label: "Lengthen rest by 15 seconds", by: 15)
        }
        .frame(maxWidth: 300)
        .disabled(session.pausedAt != nil)
    }

    private func adjustButton(_ title: String, label: String, by seconds: TimeInterval) -> some View {
        Button { live.update { s, now in s.adjustRest(by: seconds, at: now) } } label: {
            Text(title).font(.headline.monospacedDigit()).frame(width: 48, height: 48)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }

    /// The ring, full, once every set is done.
    private var allDone: some View {
        ZStack {
            Circle().stroke(Theme.Palette.success, lineWidth: 14)
            VStack(spacing: Theme.Spacing.s) {
                Image(systemName: "checkmark").font(.system(size: timerSize / 2, weight: .bold))
                    .foregroundStyle(Theme.Palette.success)
                Text("All sets done").font(.title3.weight(.semibold))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 280, maxHeight: 280)
        .padding(.top, Theme.Spacing.s)
    }

    /// "Up next · Set 3 of 3" over "Bench press · 10 · BW".
    @ViewBuilder
    private var upNext: some View {
        if let next = session.draft, let position = session.currentSetPosition {
            VStack(spacing: 2) {
                Text("Up next · Set \(position.number) of \(position.of)").font(.subheadline).foregroundStyle(.secondary)
                Text("\(next.title) · \(LiveFormat.set(next))").font(.headline).monospacedDigit().lineLimit(1)
            }
            .padding(.horizontal)
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

extension StrengthSession.Step {
    /// Shared by the set page and the Live Activity.
    var symbol: String {
        switch self {
        case .resume, .startHold: "play.fill"
        case .logSet, .endHold: "checkmark"
        case .nextSet: "forward.end"
        case .finish: "flag.checkered"
        }
    }
}
