import Foundation
import UserNotifications

// MARK: - Reminder Scheduler
//
// Bridges ReminderStore to the OS notification system ("Erweiterte Reminder").
//
//   • Static reminders are registered with UNUserNotificationCenter as repeating
//     UNCalendarNotificationTriggers, so they fire at the exact configured time
//     even when the app is closed. `reconcile()` is idempotent: it clears every
//     reminder request we own and re-adds the enabled static ones, so it can be
//     called freely after any edit and on launch (pending requests are dropped
//     on reboot / app update).
//
//   • Dynamic reminders are delivered from the background refresh (their body is
//     composed from fresh data). This type only tracks a per-rule "delivered
//     today" watermark so the same dynamic reminder isn't posted twice in a day.

@MainActor
final class ReminderScheduler {
    static let shared = ReminderScheduler()

    private let center = UNUserNotificationCenter.current()
    /// All notification request identifiers we own start with this prefix, so we
    /// can clear them without touching the proactive digest's requests.
    private let idPrefix = "trigenius.reminder."
    private let deliveredKeyPrefix = "trigenius.reminder.delivered."

    private init() {}

    // MARK: - Static reminders

    /// Re-register all enabled static reminders with the OS. Idempotent.
    func reconcile() async {
        // Remove every request we previously scheduled.
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
        if !ours.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ours) }

        guard await NotificationCenterService.shared.isAuthorized else { return }

        for rule in ReminderStore.shared.rules where rule.enabled && !rule.kind.isDynamic {
            await schedule(rule)
        }
    }

    private func schedule(_ rule: ReminderRule) async {
        let content = UNMutableNotificationContent()
        content.title = "TriGenius"
        content.body = rule.body
        content.sound = .default
        if let prompt = rule.kind.followUpPrompt {
            content.userInfo[NotificationCenterService.followUpPromptKey] = prompt
        }

        // No weekdays → fire daily at the time. Otherwise one request per weekday.
        let weekdays: [Int?] = rule.weekdays.isEmpty ? [nil] : rule.weekdays.map { $0 }
        for weekday in weekdays {
            var comps = DateComponents()
            comps.hour = rule.hour
            comps.minute = rule.minute
            if let weekday { comps.weekday = weekday }
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
            let id = weekday.map { "\(idPrefix)\(rule.id).\($0)" } ?? "\(idPrefix)\(rule.id)"
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }

    // MARK: - Dynamic reminder dedup

    private func deliveredKey(_ ruleID: String) -> String { deliveredKeyPrefix + ruleID }

    func dynamicDeliveredToday(_ ruleID: String, now: Date = Date()) -> Bool {
        let t = UserDefaults.standard.double(forKey: deliveredKey(ruleID))
        guard t > 0 else { return false }
        return Calendar.current.isDate(Date(timeIntervalSince1970: t), inSameDayAs: now)
    }

    func markDynamicDelivered(_ ruleID: String, now: Date = Date()) {
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: deliveredKey(ruleID))
    }

    // MARK: - Developer / testing

    /// Bodies of the static reminders currently registered with the OS — so the
    /// developer can confirm `reconcile()` registered what they expect.
    func pendingReminderBodies() async -> [String] {
        let pending = await center.pendingNotificationRequests()
        return pending
            .filter { $0.identifier.hasPrefix(idPrefix) }
            .map { $0.content.body }
            .sorted()
    }
}
