import SwiftUI

// MARK: - Exercise sets card
//
// The one strength table, for a plan and a recorded session alike
// (`StrengthSets.Block`), under the muscle map of what its sets work: each
// exercise names its group and its sets line up underneath, numbered per
// exercise within a block. A plan keeps its circuits
// (a header, members indented) and rest steps; a recorded session paired with
// its plan shows the prescription in parentheses beside reps, weight and time
// ("11 (10)"). A column shows only when some line carries it.

struct ExerciseSetsCard: View {
    let blocks: [StrengthSets.Block]
    let onEdit: () -> Void

    private struct DisplayRow: Identifiable {
        enum Kind {
            case circuit(rounds: Int, restSeconds: Double?)
            case rest(seconds: Double)
            case title(String)
            case set(number: Int, line: StrengthSets.Line)
        }
        let id: Int
        let kind: Kind
        let indented: Bool
        let divider: Bool
    }

    private var displayRows: [DisplayRow] {
        var out: [DisplayRow] = []
        func add(_ kind: DisplayRow.Kind, indented: Bool, divider: Bool = false) {
            out.append(DisplayRow(id: out.count, kind: kind, indented: indented, divider: divider))
        }
        for block in blocks {
            let circuit = block.rounds > 1
            if circuit { add(.circuit(rounds: block.rounds, restSeconds: block.roundRestSeconds), indented: false, divider: true) }
            var counts: [String: Int] = [:]
            for item in block.items {
                switch item {
                case .rest(let seconds):
                    add(.rest(seconds: seconds), indented: circuit, divider: !circuit)
                case .exercise(let lines):
                    for (index, line) in lines.enumerated() {
                        if index == 0 || lines[index - 1].title != line.title {
                            add(.title(line.title), indented: circuit, divider: !circuit)
                        }
                        counts[line.title, default: 0] += 1
                        add(.set(number: counts[line.title] ?? 1, line: line), indented: circuit)
                    }
                }
            }
        }
        return out
    }

    var body: some View {
        let lines = blocks.flatMap { $0.items.flatMap(\.lines) }
        let sets = lines.compactMap(\.set)
        let plans = lines.compactMap(\.plan)
        let flagged = lines.filter(\.isFlagged).count
        let showPlan = !plans.isEmpty
        let showReps = (sets + plans).contains { $0.reps != nil }
        let showTime = (sets + plans).contains { $0.seconds != nil }
        let showPlanTime = plans.contains { $0.seconds != nil }
        let showRest = sets.contains { $0.restSeconds != nil }
        let targets = TissueSession.targets(sets)
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Label("Exercises", systemImage: "dumbbell").font(.headline)
                Spacer()
                if flagged > 0 {
                    Label("\(flagged) to check", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline).foregroundStyle(.orange)
                }
                Button("Edit", action: onEdit)
                    .font(.subheadline)
                    .buttonStyle(.borderless)
            }
            if !targets.isEmpty {
                MuscleMap(targets: targets)
                    .padding(.vertical, Theme.Spacing.s)
            }
            Grid(alignment: .trailing, horizontalSpacing: Theme.Spacing.s, verticalSpacing: Theme.Spacing.xs) {
                GridRow {
                    Text("Set").gridColumnAlignment(.leading)
                    if showReps { column(showPlan ? "Reps (plan)" : "Reps") }
                    column(showPlan ? "kg (plan)" : "kg")
                    if showTime { column(showPlanTime ? "Time (plan)" : "Time") }
                    if showRest { column("Rest") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(displayRows) { row in
                    if row.divider { Divider() }
                    switch row.kind {
                    case .circuit(let rounds, let rest):
                        fullWidth(Label(rest.map { "\(rounds)× circuit · \(Self.time($0)) rest between rounds" } ?? "\(rounds)× circuit",
                                        systemImage: "repeat")
                            .font(.subheadline.weight(.semibold)), row)
                    case .rest(let seconds):
                        fullWidth(Label("Rest \(Self.time(seconds))", systemImage: "pause.circle")
                            .font(.subheadline).foregroundStyle(.secondary), row)
                    case .title(let title):
                        fullWidth(Text(title).font(.subheadline.weight(.semibold)), row)
                    case .set(let number, let line):
                        GridRow {
                            Text("\(number)")
                                .foregroundStyle(.secondary)
                                .padding(.leading, row.indented ? Theme.Spacing.m : 0)
                            if showReps { reps(line, showPlan: showPlan) }
                            cell(line.set.map(Self.load) ?? "–", plan: line.plan.map(Self.load), showPlan: showPlan)
                            if showTime {
                                cell(Self.time(line.set?.seconds), plan: line.plan?.seconds.map(Self.time), showPlan: showPlanTime)
                            }
                            if showRest { Text(Self.time(line.set?.restSeconds)) }
                        }
                        .font(.subheadline.monospacedDigit())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// Flexible header cells spread the value columns across the card.
    private func column(_ title: String) -> some View {
        Text(title).frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// A row outside `GridRow` spans every column.
    private func fullWidth(_ content: some View, _ row: DisplayRow) -> some View {
        content
            .padding(.leading, row.indented ? Theme.Spacing.m : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The recorded value, and — beside a plan — the prescription in parentheses
    /// ("–" where this set wasn't prescribed).
    private func cell(_ value: String, plan: String?, showPlan: Bool) -> Text {
        guard showPlan else { return Text(value) }
        return Text("\(value) \(Text("(\(plan ?? "–"))").foregroundStyle(.secondary))")
    }

    @ViewBuilder
    private func reps(_ line: StrengthSets.Line, showPlan: Bool) -> some View {
        let text = cell(line.set?.reps.map(String.init) ?? "–", plan: line.plan?.reps.map(String.init), showPlan: showPlan)
        if line.isFlagged {
            Label { text } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.orange)
        } else {
            text
        }
    }

    /// Kilograms without the unit (the column says it), or bodyweight.
    static func load(_ set: StrengthSets.SetRow) -> String {
        set.weightKg.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "BW"
    }

    static func time(_ seconds: Double?) -> String {
        seconds.map { Duration.seconds($0.rounded()).formatted(.time(pattern: .minuteSecond)) } ?? "–"
    }
}
