import SwiftUI

// MARK: - Activities (the search tab)
//
// Every completed workout, newest first in training weeks, searchable by name, sport
// and month and filterable by sport. Read-only: a row opens the workout's detail.

struct ActivitiesView: View {
    @State private var items: [ActivityListItem] = []
    @State private var loaded = false
    @State private var query = ""
    @State private var sport: SportFamily?
    @Environment(CoachRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        let weeks = ActivityList.weeks(items, sport: sport, query: query)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.l) {
                ForEach(weeks) { week in
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        weekHeader(week)
                        VStack(spacing: 0) {
                            ForEach(Array(week.items.enumerated()), id: \.element.id) { index, item in
                                if index > 0 {
                                    Divider().padding(.leading, WorkoutRow.dividerInset).padding(.trailing, Theme.Spacing.m)
                                }
                                NavigationLink { WorkoutDetailDestination(id: item.id) } label: {
                                    WorkoutRow(date: item.start, family: item.family, title: item.name,
                                               summary: summary(item))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .contentCard(padding: 0)
                    }
                }
            }
            .padding(Theme.Spacing.l)
        }
        .overlay { if loaded && weeks.isEmpty { emptyState } }
        .searchable(text: $query, prompt: "Name, sport or month")
        .safeAreaBar(edge: .top) {
            ScreenHeader("Activities") { sportMenu }
                .padding(.horizontal)
                .padding(.vertical, Theme.Spacing.s)
        }
        .background(Color.appBackground)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .navigationDestination(item: $router.openedWorkoutID) { WorkoutDetailDestination(id: $0) }
        .onAppear { if !loaded { reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .trainingDataDidChange)) { _ in reload() }
    }

    private func reload() {
        items = TrainingDataStore.shared.activityListItems()
        loaded = true
    }

    private var sportMenu: some View {
        Menu {
            Picker("Sport", selection: $sport) {
                Text("All sports").tag(SportFamily?.none)
                ForEach(SportFamily.allCases) { Text($0.displayName).tag(SportFamily?.some($0)) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text(sport?.displayName ?? "All sports")
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
            .headerSegment()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .headerPill()
    }

    /// The week's dates, then its totals — under a sport filter only that sport's,
    /// with its distance (summed across sports, a distance means nothing).
    private func weekHeader(_ week: ActivityWeek) -> some View {
        let end = week.weekStart.addingTimeInterval(6 * 86400)
        let t = week.totals
        var parts = [durationHM(t.durationMinutes), "\(Int(t.tss.rounded())) TSS"]
        if let sport {
            if t.distanceKm > 0 { parts.insert(sport.distanceLabel(t.distanceKm, decimals: 1), at: 1) }
            parts.insert(sport.displayName, at: 0)
        }
        return HStack(alignment: .firstTextBaseline) {
            Text((week.weekStart..<end).formatted(.interval.day().month(.abbreviated).year()))
                .font(.headline)
            Spacer(minLength: Theme.Spacing.s)
            Text(parts.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func summary(_ item: ActivityListItem) -> String {
        var parts: [String] = []
        if let tss = item.tss, tss > 0 { parts.append("\(Int(tss.rounded())) TSS") }
        parts.append(durationHM(item.durationMinutes))
        if item.distanceKm > 0 { parts.append(item.family.distanceLabel(item.distanceKm)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var emptyState: some View {
        if items.isEmpty {
            ContentUnavailableView("No activities yet", systemImage: "figure.run",
                                   description: Text("Completed workouts appear here after a sync."))
        } else if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView("No \(sport?.displayName.lowercased() ?? "") activities",
                                   systemImage: sport?.icon ?? "figure.run")
        }
    }
}
