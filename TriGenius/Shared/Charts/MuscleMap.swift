import SwiftUI

// MARK: - Muscle map
//
// The groups a strength session works (`TissueSession.targets`), front and back side
// by side: primary movers in the heavy load colour, secondary ones a step lighter on
// the same ramp, the rest clear.

struct MuscleMap: View {
    let targets: [TissueGroup: TissueSession.Target]

    var body: some View {
        let fills = targets.mapValues(Self.color)
        VStack(spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.xl) {
                ForEach([TissueBodyMap.Side.front, .back]) { side in
                    TissueBodyMap(side: side, fills: fills)
                }
            }
            .frame(height: 200)
            HStack(spacing: Theme.Spacing.m) {
                legend(Self.color(.primary), "Primary")
                legend(Self.color(.secondary), "Secondary")
                legend(Theme.Palette.Tissue.clear, "Untargeted")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(text)
        }
    }

    private static func color(_ target: TissueSession.Target) -> Color {
        Theme.Palette.Tissue.load(target == .primary ? .heavy : .moderate)
    }
}
