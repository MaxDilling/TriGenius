import SwiftUI

/// A titled row of numbered steps for a subjective rating (feel, RPE, pain).
/// `pick` gets the tapped step, or nil when the selected step is tapped again.
struct RatingScale: View {
    let title: String
    let value: Int?
    let range: ClosedRange<Int>
    let caption: String?
    let pick: (Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(caption ?? "–").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            }
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(range, id: \.self) { step in
                    Button { pick(step == value ? nil : step) } label: {
                        Text("\(step)")
                            .font(.subheadline.weight(.medium)).monospacedDigit()
                            .foregroundStyle(step == value ? Color.white : .primary)
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(step == value ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.fill.tertiary),
                                        in: .rect(cornerRadius: Theme.Radius.s))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
