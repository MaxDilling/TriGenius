import SwiftUI

// MARK: - Dashboard layout
//
// Settings → Dashboard → Dashboard layout: toggle each dashboard section on/off
// and drag to reorder. Backed by `AppSettings.dashboardLayout`; the dashboard
// header is fixed (it's the Settings entry point) and not listed here.

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
            } footer: {
                Text("Drag to reorder. Hiding the AI summary also skips its LLM call.")
            }
        }
        .navigationTitle("Dashboard Layout")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
        #endif
    }
}
