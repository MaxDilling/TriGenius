import Foundation

// MARK: - Coach Debug Log
//
// A long-lived, observable record of what the coach did under the hood: tool
// calls and their results. Deliberately decoupled from any single chat turn so
// that later background work (proactive triggers, scheduled syncs, push
// evaluation) can log into the same place.
//
// Recording is gated by the app's Debug Mode (see `CoachBrain.isDebugEnabled`),
// so there is no overhead when debugging is off.

/// One observed tool execution.
struct CoachToolEvent: Identifiable, Sendable {
    let id = UUID()
    let name: String
    /// The arguments the model passed, JSON-encoded for display.
    let argumentsJSON: String
    /// The (possibly truncated) tool result.
    let resultPreview: String
    let timestamp: Date

    init(name: String, argumentsJSON: String, result: String, timestamp: Date = Date()) {
        self.name = name
        self.argumentsJSON = argumentsJSON
        self.resultPreview = CoachToolEvent.truncate(result)
        self.timestamp = timestamp
    }

    private static func truncate(_ s: String, limit: Int = 800) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "… (\(s.count) chars)"
    }
}

@MainActor
@Observable
final class CoachDebugLog {
    static let shared = CoachDebugLog()
    private init() {}

    private(set) var events: [CoachToolEvent] = []

    /// Keep the buffer bounded so a long-running session can't grow without limit.
    private let maxEvents = 200

    func record(_ event: CoachToolEvent) {
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
    }

    func clear() {
        events.removeAll()
    }
}
