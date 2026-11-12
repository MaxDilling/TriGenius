#if os(iOS)
import ActivityKit
import Foundation

// MARK: - Live Activity
//
// Mirrors the running session onto the Lock Screen and the Dynamic Island
// (`LiveStrengthAttributes`, drawn by the widget extension): requested with the
// session, updated on every change that alters what it shows, ended when the
// session ends. A rest or hold that runs out while the app is suspended gets no
// update — its content goes stale at that moment and the activity says so.

@MainActor
enum LiveStrengthActivity {
    private static var shown: LiveStrengthAttributes.ContentState?

    static func sync(_ session: StrengthSession?) {
        guard let session, session.endedAt == nil else {
            shown = nil
            Task {
                for activity in Activity<LiveStrengthAttributes>.activities {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
            return
        }
        let state = state(session)
        let isRunning = !Activity<LiveStrengthAttributes>.activities.isEmpty
        guard state != shown || !isRunning else { return }
        shown = state
        let content = ActivityContent(state: state, staleDate: staleDate(state.phase))
        if isRunning {
            Task { await Activity<LiveStrengthAttributes>.activities.first?.update(content) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            _ = try? Activity.request(attributes: LiveStrengthAttributes(planName: session.planName), content: content)
        }
    }

    private static func state(_ s: StrengthSession) -> LiveStrengthAttributes.ContentState {
        let phase: LiveStrengthAttributes.ContentState.Phase
        if s.pausedAt != nil {
            phase = .paused
        } else if s.isComplete {
            phase = .allDone
        } else {
            switch s.phase(at: .now) {
            case .working: phase = .working
            case .holding(let since): phase = .holding(since: since, until: since.addingTimeInterval(s.current?.seconds ?? 0))
            case .resting(let since, let until): phase = .resting(since: since, until: until)
            }
        }
        let detail = s.draft.flatMap { set in
            s.currentSetPosition.map { "Set \($0.number) of \($0.of) · \(LiveFormat.set(set))" }
        }
        return .init(phase: phase, title: s.current?.title ?? s.planName, detail: detail ?? "",
                     doneSets: s.doneSets, totalSets: s.totalSets,
                     clockStart: s.startedAt.addingTimeInterval(s.pausedSeconds), pausedAt: s.pausedAt)
    }

    private static func staleDate(_ phase: LiveStrengthAttributes.ContentState.Phase) -> Date? {
        switch phase {
        case .holding(_, let until), .resting(_, let until?): until
        default: nil
        }
    }
}
#endif
