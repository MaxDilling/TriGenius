import SwiftUI

// MARK: - Planned Structure Card
//
// The step-by-step breakdown of a planned session (warm-up / repeat blocks /
// cool-down with their per-step targets). Shared by the planned-workout detail
// view and the completed-workout detail view (where it shows what was planned,
// next to the achieved metrics) so both render the structure identically.

struct PlannedStructureCard: View {
    let structure: PlannedWorkoutStructure
    /// Accent for icons / the repeat marker — the sport `family.color`.
    let accent: Color
    /// Card heading: "Structure" on a plan, "Planned structure" on a completed workout.
    var title: String = "Structure"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Label(title, systemImage: "list.bullet.indent").font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(structure.steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 { Divider() }
                    stepRow(step)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    @ViewBuilder
    private func stepRow(_ step: PlannedDisplayStep) -> some View {
        if step.isGroup {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: 6) {
                    Image(systemName: "repeat")
                        .font(.caption.weight(.semibold)).foregroundStyle(accent)
                    Text("\(step.repeatCount)×").font(.subheadline.weight(.semibold))
                    Spacer()
                }
                ForEach(step.steps) { leaf in
                    leafRow(leaf)
                        .padding(.leading, Theme.Spacing.l)
                }
            }
            .padding(.vertical, Theme.Spacing.s)
        } else if let leaf = step.leaf {
            leafRow(leaf)
                .padding(.vertical, Theme.Spacing.s)
        }
    }

    private func leafRow(_ leaf: PlannedStepLeaf) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: leaf.icon)
                .font(.caption).foregroundStyle(accent)
                .frame(width: 20)
            Text(leaf.typeLabel).font(.subheadline)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(PlannedWorkoutFormat.extent(leaf))
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                if let target = structure.targetText(leaf) {
                    Text(target).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }
}
