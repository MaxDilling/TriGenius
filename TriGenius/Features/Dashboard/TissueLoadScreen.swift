import SwiftUI

// MARK: - Tissue Load screen (tap-through from the dashboard card)
//
// The full picture in one card: today's state on the figure above every group over the
// forecast window as a grid, with the legend. Front and back sit side by side where the
// width allows, behind a Back/Front switch where it doesn't. A group opens its detail
// from either.

struct TissueLoadScreen: View {
    let input: TissueCardModel.Input
    var onAskCoach: (String) -> Void = { _ in }

    @State private var side: TissueBodyMap.Side = .back
    @State private var selected: TissueGroup?

    private var wide = WideLayout()

    init(input: TissueCardModel.Input, onAskCoach: @escaping (String) -> Void = { _ in }) {
        self.input = input
        self.onAskCoach = onAskCoach
    }

    private var model: TissueGridModel { TissueGridModel.make(input) }

    private var statesToday: [TissueGroup: TissueDayState] {
        input.forecasts.reduce(into: [:]) { result, forecast in
            result[forecast.group] = forecast.today
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if !wide.isWide { sidePicker }
                figures
                TissueGrid(days: model.days, rows: model.rows,
                           isWide: wide.isWide, onSelect: { selected = $0 })
                TissueLegend()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .padding(Theme.Spacing.l)
        }
        .background(Color.appBackground)
        .navigationTitle("Tissue Load")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(item: $selected) { group in
            if let detail = TissueGroupDetailModel.make(group: group, input: input) {
                TissueGroupDetail(model: detail, onAskCoach: onAskCoach)
            }
        }
    }

    private var sidePicker: some View {
        Picker("Side", selection: $side) {
            ForEach(TissueBodyMap.Side.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder private var figures: some View {
        if wide.isWide {
            HStack(alignment: .top, spacing: Theme.Spacing.l) {
                figure(.front)
                figure(.back)
            }
            .frame(maxWidth: .infinity)
        } else {
            figure(side)
                .frame(maxWidth: .infinity)
        }
    }

    private func figure(_ side: TissueBodyMap.Side) -> some View {
        TissueBodyMap(side: side, fills: statesToday.mapValues { Theme.Palette.Tissue.load($0.muscle) },
                      states: statesToday, forecasts: forecastLabels,
                      selected: selected, onSelect: { selected = $0 })
            .frame(maxWidth: wide.isWide ? 260 : 190)
    }

    private var forecastLabels: [TissueGroup: String] {
        model.rows.reduce(into: [:]) { $0[$1.group] = $1.clearLabel }
    }
}

#if DEBUG
#Preview("2.1 Tissue Load") {
    NavigationStack { TissueLoadScreen(input: TissuePreviewFixture.conflict) }
}
#endif
