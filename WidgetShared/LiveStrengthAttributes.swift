#if os(iOS)
import ActivityKit
import Foundation

// MARK: - Live strength activity
//
// The contract between the app's live strength session and its Live Activity
// (Lock Screen, Dynamic Island). Compiled into both the app and the widget
// extension, so it carries display-ready strings, never app types. Every
// running figure is a date the system counts from on its own: the app updates
// the activity only when the session changes, never per second.

nonisolated struct LiveStrengthAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        nonisolated enum Phase: Codable, Hashable {
            case working
            case holding(since: Date, until: Date)
            /// `until` nil: untimed, until the athlete moves on.
            case resting(since: Date, until: Date?)
            case paused
            case allDone
        }

        var phase: Phase
        /// The exercise under way, or coming next while resting.
        var title: String
        /// "Set 2 of 3 · 10 · BW"; empty once every set is done.
        var detail: String
        var doneSets: Int
        var totalSets: Int
        /// The workout clock's zero: the start shifted by every pause.
        var clockStart: Date
        /// Set while paused: the clock stands at `pausedAt − clockStart`.
        var pausedAt: Date?
    }
}
#endif
