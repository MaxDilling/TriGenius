import Foundation

// MARK: - Activity list
//
// The completed-activity history as the Activities screen shows it: each record
// reduced to what its row and its week's totals need, then searched, filtered by
// sport and grouped into training weeks. Under a sport filter a multisport session
// is listed whole but its week totals count only that sport's legs, as in
// `TrainingVolume`.

struct ActivityListItem: Identifiable, Sendable {
    let id: String
    /// The effective slot's day plus its start minute — the list's sort key.
    let start: Date
    let name: String
    let family: SportFamily
    let durationMinutes: Double
    let distanceKm: Double
    let tss: Double?
    let contributions: [(family: SportFamily, tss: Double, distanceKm: Double, durationMinutes: Double)]
    /// Name, sports and month + year in one string, so a keystroke only runs `contains`.
    let searchText: String

    init(_ record: WorkoutRecord) {
        id = record.id
        start = record.date.addingTimeInterval(Double(record.startMinute ?? 0) * 60)
        name = record.name
        family = SportFamily(sportKey: record.sport)
        durationMinutes = record.durationMinutes
        distanceKm = record.distanceKm
        tss = record.tss
        contributions = record.sportContributions
        let sports = Set(contributions.map(\.family) + [family]).map(\.displayName)
        searchText = ([record.name] + sports + [record.date.formatted(.dateTime.month(.wide).year())])
            .joined(separator: " ")
    }
}

struct ActivityWeek: Identifiable {
    let weekStart: Date
    let items: [ActivityListItem]
    let totals: VolumeTotals
    var id: Date { weekStart }
}

enum ActivityList {

    /// The items matching `sport` and every word of `query`, grouped by training
    /// week. `items` newest first; weeks come out newest first too.
    static func weeks(_ items: [ActivityListItem], sport: SportFamily?, query: String) -> [ActivityWeek] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var groups: [(weekStart: Date, items: [ActivityListItem])] = []
        for item in items {
            guard sport.map({ s in item.contributions.contains { $0.family == s } }) ?? true,
                  words.allSatisfy(item.searchText.localizedStandardContains) else { continue }
            let weekStart = TrainingVolume.weekStart(of: item.start)
            if groups.last?.weekStart == weekStart { groups[groups.count - 1].items.append(item) }
            else { groups.append((weekStart, [item])) }
        }
        return groups.map { ActivityWeek(weekStart: $0.weekStart, items: $0.items, totals: totals($0.items, sport: sport)) }
    }

    /// Whole sessions without a filter; with one, only that sport's legs.
    static func totals(_ items: [ActivityListItem], sport: SportFamily?) -> VolumeTotals {
        var t = VolumeTotals()
        for item in items {
            guard let sport else {
                t.tss += item.tss ?? 0
                t.distanceKm += item.distanceKm
                t.durationMinutes += item.durationMinutes
                t.sessions += 1
                continue
            }
            for c in item.contributions where c.family == sport {
                t.tss += c.tss
                t.distanceKm += c.distanceKm
                t.durationMinutes += c.durationMinutes
                t.sessions += 1
            }
        }
        return t
    }
}
