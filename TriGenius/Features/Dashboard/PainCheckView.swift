import SwiftUI

// MARK: - Pain check-in
//
// "Where does it hurt right now?" — pick areas on the body map (or from the menu,
// for the ones too thin to tap), rate each 1–10, save one `PainReport`.

struct PainCheckView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var side: TissueBodyMap.Side = .back
    @State private var picked: Set<TissueGroup> = []
    @State private var severities: [TissueGroup: Int] = [:]

    /// A neutral state per group: what makes every mapped region a tap target.
    private static let tappable = Dictionary(uniqueKeysWithValues: TissueGroup.allCases.map {
        ($0, TissueDayState(date: .now, muscle: .fresh))
    })

    private var fills: [TissueGroup: Color] {
        picked.reduce(into: [:]) {
            $0[$1] = Theme.Palette.Tissue.clear.mix(with: Theme.Palette.Tissue.heavy,
                                                    by: Double(severities[$1] ?? 5) / 10)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Picker("Side", selection: $side) {
                        ForEach(TissueBodyMap.Side.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    TissueBodyMap(side: side, fills: fills, states: Self.tappable, onSelect: toggle)
                        .frame(maxWidth: 220)
                        .frame(maxWidth: .infinity)
                    ForEach(picked.sorted { $0.anatomicalRank < $1.anatomicalRank }, id: \.self) { group in
                        RatingScale(title: group.label, value: severities[group], range: 1...10,
                                    caption: severities[group].map { "\($0) / 10" }) { severities[group] = $0 }
                    }
                    Menu {
                        ForEach(TissueGroup.allCases.filter { !picked.contains($0) }, id: \.self) { group in
                            Button(group.label) { picked.insert(group) }
                        }
                    } label: {
                        Label("Add an area", systemImage: "plus")
                    }
                }
                .cardSurface()
                .padding(Theme.Spacing.l)
            }
            .background(Color.appBackground)
            .navigationTitle("Where does it hurt?")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        PainReportStore.shared.add(severities)
                        dismiss()
                    }
                    .disabled(severities.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 640)
        #endif
    }

    private func toggle(_ group: TissueGroup) {
        if picked.remove(group) != nil {
            severities[group] = nil
        } else {
            picked.insert(group)
        }
    }
}
