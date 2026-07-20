import Foundation

// MARK: - Chat Store
//
// Persists the live coach conversation so it survives an app restart. One
// session at a time, held as an ordered list of text/card turns in a JSON file
// in Application Support (deliberately device-local, not CloudKit — a transient
// chat shouldn't mirror across devices).
//
// The same saved record rehydrates both sides on launch: `CoachBrain` rebuilds
// its LLM context from the text turns, the chat UI rebuilds its bubbles + cards.
// Cleared only by the explicit Reset button (`clear()`) or, on load, when the
// last turn is older than `retention` (24h) — nothing else wipes it.

/// One persisted chat turn — a user/coach text bubble, or a coach card row.
@MainActor
struct SavedTurn {
    /// "user" | "assistant". A card row is always "assistant" with empty text.
    let role: String
    let text: String
    let timestamp: Date
    /// Set only for card rows — the serialized `ChatCard` (`nil` for text turns).
    let card: ChatCard?

    init(role: String, text: String, timestamp: Date, card: ChatCard? = nil) {
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.card = card
    }

    init?(from d: [String: Any]) {
        guard let role = d["role"] as? String else { return nil }
        self.role = role
        self.text = d["text"] as? String ?? ""
        self.timestamp = (d["timestamp"] as? TimeInterval).map(Date.init(timeIntervalSince1970:)) ?? Date()
        self.card = (d["card"] as? [String: Any]).flatMap(ChatCard.init(from:))
    }

    func toDict() -> [String: Any] {
        var d: [String: Any] = ["role": role, "text": text, "timestamp": timestamp.timeIntervalSince1970]
        if let card { d["card"] = card.toDict() }
        return d
    }
}

@MainActor
final class ChatStore {
    static let shared = ChatStore()

    /// The persisted session, already expiry-filtered (empty if stale/none).
    private(set) var turns: [SavedTurn]

    private let storageURL: URL

    /// Drop a session whose last activity is older than this on load.
    private let retention: TimeInterval = 24 * 60 * 60

    init(filename: String = "chat_session.json") {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storageURL = dir.appendingPathComponent(filename)
        turns = []
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = raw["turns"] as? [[String: Any]] else { return }
        let loaded = arr.compactMap(SavedTurn.init(from:))
        // Expire the whole session once its most recent turn ages past retention.
        if let last = loaded.last, Date().timeIntervalSince(last.timestamp) > retention {
            clear()
            return
        }
        turns = loaded
    }

    /// Replace the persisted session with the current transcript.
    func save(_ turns: [SavedTurn]) {
        self.turns = turns
        let dict: [String: Any] = ["turns": turns.map { $0.toDict() }]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return }
        let url = storageURL
        DispatchQueue.global(qos: .utility).async {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Wipe the session (the Reset button / 24h expiry).
    func clear() {
        turns = []
        try? FileManager.default.removeItem(at: storageURL)
    }
}
