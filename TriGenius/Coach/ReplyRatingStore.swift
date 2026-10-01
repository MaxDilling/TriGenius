import Foundation

// MARK: - Reply Rating Store
//
// The athlete's 👍/👎 on coach replies: one JSON file per rating in
// `Application Support/reply_ratings`, device-local like `ReportStore`. A file
// carries what replaying the reply needs (`CoachBrain.ratingContext`), so each is
// written once instead of rewriting a growing list.

/// The athlete's vote on a coach reply; `id` names its file.
struct ReplyRating {
    let id: String
    let isUp: Bool
}

@MainActor
@Observable
final class ReplyRatingStore {
    static let shared = ReplyRatingStore()

    /// The ratings that exist. A chat bubble's vote counts only while its id is
    /// here, so deleting ratings in Settings clears the thumbs too.
    private(set) var ids: Set<String>

    private let directory: URL

    private init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("reply_ratings")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        ids = Set(names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
    }

    private func file(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    func save(id: String, _ rating: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(rating),
              let data = try? JSONSerialization.data(withJSONObject: rating, options: [.prettyPrinted, .sortedKeys]),
              (try? data.write(to: file(id), options: .atomic)) != nil
        else { return }
        ids.insert(id)
    }

    func delete(id: String) {
        try? FileManager.default.removeItem(at: file(id))
        ids.remove(id)
    }

    func deleteAll() {
        for id in ids { try? FileManager.default.removeItem(at: file(id)) }
        ids = []
    }

    /// Every stored rating, newest first.
    func all() -> [[String: Any]] {
        ids.compactMap { id in
            (try? Data(contentsOf: file(id))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        .sorted { ($0["timestamp"] as? Double ?? 0) > ($1["timestamp"] as? Double ?? 0) }
    }
}
