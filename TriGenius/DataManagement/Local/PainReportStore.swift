import Foundation

// MARK: - Pain Report Store
//
// The athlete's pain check-ins ("where does it hurt right now?"), kept as one
// JSON file in Application Support — device-local, outside SwiftData. A report
// is feedback for calibrating the tissue model: it never reaches the coach's
// HARD LIMITS and no forecast reads it.

/// One check-in: how much each reported area hurt (1–10) at that moment.
struct PainReport: Identifiable {
    let id: String
    let date: Date
    let severities: [TissueGroup: Int]

    init(id: String = UUID().uuidString, date: Date = Date(), severities: [TissueGroup: Int]) {
        self.id = id
        self.date = date
        self.severities = severities
    }

    init?(from d: [String: Any]) {
        guard let id = d["id"] as? String, let timestamp = d["timestamp"] as? Double,
              let areas = d["areas"] as? [String: Int] else { return nil }
        self.id = id
        self.date = Date(timeIntervalSince1970: timestamp)
        self.severities = areas.reduce(into: [:]) { result, area in
            if let group = TissueGroup(rawValue: area.key) { result[group] = area.value }
        }
    }

    func toDict() -> [String: Any] {
        ["id": id, "timestamp": date.timeIntervalSince1970,
         "areas": Dictionary(uniqueKeysWithValues: severities.map { ($0.key.rawValue, $0.value) })]
    }
}

@MainActor
@Observable
final class PainReportStore {
    static let shared = PainReportStore()

    /// Newest first.
    private(set) var reports: [PainReport] = []

    private let storageURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storageURL = dir.appendingPathComponent("pain_reports.json")
        if let data = try? Data(contentsOf: storageURL),
           let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            reports = rows.compactMap(PainReport.init(from:))
        }
    }

    func add(_ severities: [TissueGroup: Int]) {
        reports.insert(PainReport(severities: severities), at: 0)
        save()
    }

    func delete(ids: Set<String>) {
        reports.removeAll { ids.contains($0.id) }
        save()
    }

    func deleteAll() {
        reports = []
        try? FileManager.default.removeItem(at: storageURL)
    }

    var exportRows: [[String: Any]] { reports.map { $0.toDict() } }

    private func save() {
        guard let data = try? JSONSerialization.data(withJSONObject: exportRows, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
