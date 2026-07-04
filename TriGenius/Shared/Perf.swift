import os

/// Performance signposts for Instruments' "Points of Interest" track.
///
/// Wrap a whole-function span so it shows up by name in a trace:
/// ```
/// let s = Perf.begin("syncAll"); defer { Perf.end(s) }
/// ```
/// Pass a dynamic label as the second argument when one static name covers several
/// cases (`Perf.begin("sync", source.rawValue)`). Effectively free when not recording.
// `nonisolated` so signposts can wrap spans on any actor (e.g. Garmin's
// non-isolated network methods), not just the main actor the module defaults to.
// OSSignposter is Sendable and thread-safe.
nonisolated enum Perf {
    static let signposter = OSSignposter(subsystem: "net.Narica.TriGenius", category: .pointsOfInterest)

    struct Span {
        let name: StaticString
        let state: OSSignpostIntervalState
    }

    static func begin(_ name: StaticString, _ label: String = "") -> Span {
        Span(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID(), "\(label, privacy: .public)"))
    }

    static func end(_ span: Span) {
        signposter.endInterval(span.name, span.state)
    }

    /// A single instant (no duration) — for counting occurrences in a trace,
    /// e.g. notification receipts/posts.
    static func event(_ name: StaticString, _ label: String = "") {
        signposter.emitEvent(name, "\(label, privacy: .public)")
    }
}
