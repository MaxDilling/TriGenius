#if DEBUG
import SwiftUI

// The card in the states of flow 1, from `TissuePreviewFixture` — the real model
// over synthetic weeks, pinned to the Monday the design frames were drawn for.

private struct TissueCardPreview: View {
    let title: String
    let model: TissueCardModel
    var mode: TissueCardMode = .sevenDays
    var chronic: TissueChronicModel?

    var body: some View {
        // Scrolling, because at the accessibility type sizes the card is taller than
        // the screen — the dashboard scrolls too.
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                SectionHeading("Tissue Load") { EmptyView() }
                TissueLoadCard(mode: mode, model: model, chronic: chronic)
            }
            .padding(Theme.Spacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.appBackground)
    }
}

#Preview("1.1 Build week") {
    TissueCardPreview(title: "1.1 · Build week", model: card(TissuePreviewFixture.buildWeek))
}

#Preview("1.2 Taper") {
    TissueCardPreview(title: "1.2 · Taper", model: card(TissuePreviewFixture.taper))
}

#Preview("1.3 Conflict") {
    TissueCardPreview(title: "1.3 · Conflict", model: card(TissuePreviewFixture.conflict))
}

#Preview("6 weeks") {
    TissueCardPreview(title: "6 weeks · chronic", model: card(TissuePreviewFixture.conflict),
                      mode: .sixWeeks, chronic: TissuePreviewFixture.chronic)
}

private func card(_ input: TissueCardModel.Input) -> TissueCardModel {
    TissueCardModel.make(input, calendar: TissuePreviewFixture.calendar, locale: TissuePreviewFixture.locale)
}
#endif
