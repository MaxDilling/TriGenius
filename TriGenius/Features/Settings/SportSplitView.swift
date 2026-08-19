import SwiftUI

// MARK: - Sport split
//
// Settings → Dashboard → Sport split: how the week's training load divides across
// swim/bike/run. Writes `WeeklyStructure.sportRatio` — the only sport-aware input
// to the otherwise sport-agnostic ATP (`ATPSportSplit`) and the gate on the
// dashboard's weekly-target rings (`WeeklyTargets.visibleFamilies`): a discipline
// at 0 % is not programmed and gets no ring.
//
// The sliders are seeded from the store in `init` (not `onAppear`, whose timing
// let the page render an all-zero split) and edited as a local draft; the commit
// happens once the drag ends, since each write persists and reloads the dashboard.

struct SportSplitView: View {
    @ObservedObject var memory: CoachMemory

    @State private var ratio: [SportFamily: Double]

    init(memory: CoachMemory) {
        _memory = ObservedObject(wrappedValue: memory)
        _ratio = State(initialValue: Self.normalized(memory.weeklyStructure.sportRatio))
    }

    var body: some View {
        List {
            Section {
                ForEach(SportFamily.triathlon) { family in
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        HStack {
                            Label(family.displayName, systemImage: family.icon)
                            Spacer()
                            Text(ratio[family] ?? 0, format: .percent.precision(.fractionLength(0)))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: Binding(get: { ratio[family] ?? 0 },
                                              set: { rebalance(family, to: $0) }),
                               in: 0...1, step: 0.05,
                               onEditingChanged: { editing in if !editing { commit() } })
                            .tint(family.color)
                    }
                }
            } header: {
                Text("Weekly load split")
            } footer: {
                Text("Divides the week's planned load across the disciplines. Run balances the other two, so a swim or bike share you dial in stays put. A discipline set to 0 % is dropped from the plan and its ring disappears from the dashboard's weekly target.")
            }
        }
        .navigationTitle("Sport Split")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Set one discipline's share and take the difference out of the others, so the
    /// three keep summing to 100 %. Run is the balance wheel: it absorbs the change
    /// first, and only what run can't give (or take) spills to the third discipline
    /// — dialling in swim, then bike, leaves each where the athlete put it.
    private func rebalance(_ family: SportFamily, to value: Double) {
        var delta = value - (ratio[family] ?? 0)
        ratio[family] = value
        for other in Self.absorbers(for: family) {
            let current = ratio[other] ?? 0
            let next = min(max(current - delta, 0), 1)
            delta -= current - next
            ratio[other] = next
        }
    }

    /// The other two disciplines in the order they give up (or take on) share.
    private static func absorbers(for family: SportFamily) -> [SportFamily] {
        switch family {
        case .run:  return [.bike, .swim]
        case .bike: return [.run, .swim]
        default:    return [.run, .bike]
        }
    }

    private func commit() {
        memory.updateWeeklyStructure { $0.sportRatio = ratio }
    }

    /// Shares as fractions of the triathlon total — the stored weights needn't sum
    /// to 1 (the coach may set raw weights), the sliders always show percentages.
    private static func normalized(_ stored: [SportFamily: Double]) -> [SportFamily: Double] {
        let weights = SportFamily.triathlon.map { max(0, stored[$0] ?? 0) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(SportFamily.triathlon, weights.map { $0 / total }))
    }
}
