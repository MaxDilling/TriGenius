import SwiftUI

// MARK: - Coach Router
//
// App-level navigation hub shared via the SwiftUI environment. Decouples "some
// surface wants to start a chat with text X" from the chat/tab views, so a tapped
// notification, the dashboard insight card, and any future entry point all funnel
// through `openChat(prefill:)` instead of reaching into the chat view directly.
//
// `pendingPrompt` is a one-shot: `CoachChatView` consumes it (drops it into the
// input field, unsent) and clears it, so switching tabs again never re-injects a
// stale prompt.

@MainActor
@Observable
final class CoachRouter {
    enum RootTab: Hashable { case dashboard, plan, atp, coach, calendar }

    var selectedTab: RootTab = .dashboard
    /// Text to pre-fill into the chat input, awaiting consumption by the chat view.
    var pendingPrompt: String?

    /// Switch to the Coach tab and pre-fill (but do not send) the given prompt.
    func openChat(prefill: String) {
        pendingPrompt = prefill
        selectedTab = .coach
    }
}
