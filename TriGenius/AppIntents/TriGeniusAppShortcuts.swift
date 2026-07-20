import AppIntents

// MARK: - App Shortcuts
//
// Zero-setup Siri phrases; Siri AI also discovers the intents themselves
// through the app toolbox, so these cover only the highest-traffic entries.

struct TriGeniusAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetPlannedWorkoutsIntent(),
            phrases: [
                "What's my workout today in \(.applicationName)",
                "Show my \(.applicationName) training plan",
            ],
            shortTitle: "Planned Workouts",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: ScheduleWorkoutIntent(),
            phrases: ["Schedule a workout in \(.applicationName)"],
            shortTitle: "Schedule Workout",
            systemImageName: "plus.circle"
        )
    }
}
