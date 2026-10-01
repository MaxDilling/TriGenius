import SwiftUI

// MARK: - Route heatmap detail
//
// The heatmap full screen and live, opened at the card's range. The layers menu
// hides sports; every sport the range holds is shown until then.

struct RouteHeatDetailView: View {
    @State var range: TimeRange
    @State private var lines: [RouteLine] = []
    @State private var hidden: Set<SportFamily> = []

    var body: some View {
        let sports = SportFamily.allCases.filter { family in lines.contains { $0.family == family } }
        RouteHeatMap(lines: lines, interactive: true, hidden: hidden)
            .overlay(alignment: .topTrailing) {
                VStack(spacing: Theme.Spacing.m) {
                    RouteMapStyleButton()
                    if sports.count > 1 {
                        Menu("Layers", systemImage: "square.stack.3d.up") {
                            ForEach(sports) { sport in
                                Toggle(sport.displayName, isOn: Binding {
                                    !hidden.contains(sport)
                                } set: { shown in
                                    if shown { hidden.remove(sport) } else { hidden.insert(sport) }
                                })
                            }
                        }
                        #if os(iOS)
                        .menuActionDismissBehavior(.disabled)
                        #endif
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .padding(Theme.Spacing.l)
            }
            .navigationTitle(StatCard.routes.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .rangeBar($range)
            .task(id: range) { lines = await RouteCache.lines(since: range.start()) }
    }
}
