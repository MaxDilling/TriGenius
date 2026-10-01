import SwiftUI

// MARK: - Dashboard layout
//
// The dashboard's editor, from its "Edit Dashboard" button (a sheet) and Settings →
// Dashboard layout: toggle and reorder the sections (`AppSettings.dashboardLayout`),
// then pick and order the Pinned section's cards (`AppSettings.pinnedCards`) out of
// every `StatCard`. The dashboard header is fixed and not listed here.

struct DashboardLayoutView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            Section {
                ForEach($settings.dashboardLayout) { $item in
                    Toggle(isOn: $item.isVisible) {
                        Label(item.section.displayName, systemImage: item.section.icon)
                    }
                }
                .onMove { settings.dashboardLayout.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("Sections")
            } footer: {
                Text("Drag to reorder. Hiding the AI summary also skips its LLM call.")
            }

            Section("Pinned") {
                ForEach(settings.pinnedCards) { cardRow($0, pinned: true) }
                    .onMove { settings.pinnedCards.move(fromOffsets: $0, toOffset: $1) }
            }

            ForEach(StatCard.groups, id: \.title) { group in
                let unpinned = group.cards.filter { !settings.pinnedCards.contains($0) }
                if !unpinned.isEmpty {
                    Section(group.title) {
                        ForEach(unpinned) { cardRow($0, pinned: false) }
                    }
                }
            }
        }
        .navigationTitle("Dashboard Layout")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
        #endif
    }

    private func cardRow(_ card: StatCard, pinned: Bool) -> some View {
        Button { withAnimation { settings.togglePin(card) } } label: {
            Label {
                Text(card.title).foregroundStyle(.primary)
            } icon: {
                Image(systemName: pinned ? "minus.circle.fill" : "plus.circle.fill")
                    .foregroundStyle(pinned ? Theme.Palette.danger : Theme.Palette.success)
            }
        }
        .buttonStyle(.plain)
    }
}
