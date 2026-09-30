import SwiftUI

// MARK: - Hero metrics
//
// The 2–3 headline numbers at the top of a workout detail, shared by the completed
// and the planned view. A metric's `note` — how its TSS was computed — opens in a
// popover on tap rather than taking a line of its own.

struct HeroMetric: Identifiable {
    let value: String
    let label: String
    var note: String?
    var id: String { label }
}

struct HeroMetricsRow: View {
    let metrics: [HeroMetric]

    @State private var showsNote = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xl) {
            ForEach(metrics) { cell($0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, Theme.Spacing.s)
    }

    @ViewBuilder
    private func cell(_ metric: HeroMetric) -> some View {
        let cell = VStack(alignment: .leading, spacing: 2) {
            Text(metric.value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(metric.label)
                .font(.caption).foregroundStyle(.secondary)
        }
        if let note = metric.note {
            cell
                .contentShape(Rectangle())
                .onTapGesture { showsNote = true }
                .popover(isPresented: $showsNote, arrowEdge: .top) {
                    Label(note, systemImage: "function")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 280)
                        .padding()
                        .presentationCompactAdaptation(.popover)
                }
        } else {
            cell
        }
    }
}
