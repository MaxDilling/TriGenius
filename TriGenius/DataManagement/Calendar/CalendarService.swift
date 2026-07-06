import Foundation
import EventKit

// MARK: - Calendar Service
//
// EventKit wrapper that gives the coach awareness of the athlete's real-world
// schedule, so it can plan workouts around busy days. Read-only: it never
// creates or mutates calendar events.
//
// FEATURES.md "EventKit calendar + read_calendar_availability tool". Mirrors the
// data-source services in shape (a shared singleton returning plain value types),
// but it is a *cross-cutting* source (always available, like ProfileToolHandler),
// not one of the swappable `DataSource` options.

/// A single busy block on the athlete's calendar.
struct BusyWindow: Sendable, Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool

    var durationMinutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
}

/// Aggregated availability for a single calendar day.
struct DayAvailability: Sendable, Identifiable {
    let date: Date          // start of day
    let busyMinutes: Int
    let allDay: Bool        // an all-day event covers this day
    let windows: [BusyWindow]

    var id: Date { date }
}

/// A device calendar the athlete can opt in/out of for availability checks.
struct CalendarInfo: Sendable, Identifiable {
    let id: String          // EKCalendar.calendarIdentifier
    let title: String
    let sourceTitle: String // e.g. "iCloud", "Gmail" — groups shared/account calendars
    let colorHex: String
    let isSubscribed: Bool  // shared/subscribed calendars the athlete may want to skip
}

@MainActor
final class CalendarService {
    static let shared = CalendarService()

    private let store = EKEventStore()
    private init() {}

    // MARK: - Authorization

    enum AccessState {
        case notDetermined, denied, authorized

        var isAuthorized: Bool { self == .authorized }
    }

    var accessState: AccessState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied   // .denied, .restricted, .writeOnly
        }
    }

    /// Request full read access. Returns whether access is now granted. Safe to
    /// call repeatedly — already-granted access resolves immediately.
    @discardableResult
    func requestAccess() async -> Bool {
        if accessState == .authorized { return true }
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    // MARK: - Calendar selection

    /// UserDefaults key holding the identifiers of calendars the athlete opted
    /// *out* of. We store the exclusion set (not the inclusion set) so that
    /// calendars added after the athlete made their choice are included by
    /// default — the common case is wanting to drop a few shared calendars.
    private static let excludedKey = "calendar_excluded_identifiers"

    /// Identifiers of calendars excluded from availability checks.
    var excludedCalendarIdentifiers: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.excludedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.excludedKey) }
    }

    /// All event calendars on the device, grouped-friendly (sorted by source then
    /// title). Empty if access isn't granted.
    func availableCalendars() -> [CalendarInfo] {
        guard accessState == .authorized else { return [] }
        return store.calendars(for: .event)
            .map { cal in
                CalendarInfo(
                    id: cal.calendarIdentifier,
                    title: cal.title,
                    sourceTitle: cal.source?.title ?? "",
                    colorHex: Self.hex(from: cal.cgColor),
                    isSubscribed: cal.isSubscribed || cal.type == .subscription
                )
            }
            .sorted { ($0.sourceTitle, $0.title) < ($1.sourceTitle, $1.title) }
    }

    /// The EKCalendars to query, or `nil` for "all" (when nothing is excluded).
    private func includedCalendars() -> [EKCalendar]? {
        let excluded = excludedCalendarIdentifiers
        guard !excluded.isEmpty else { return nil }
        return store.calendars(for: .event)
            .filter { !excluded.contains($0.calendarIdentifier) }
    }

    // MARK: - Reads

    /// Busy windows (timed + all-day events) overlapping the `[from, to]` range,
    /// across the athlete's included calendars, ascending by start.
    func busyWindows(from: Date, to: Date) -> [BusyWindow] {
        guard accessState == .authorized else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: includedCalendars())
        return store.events(matching: predicate)
            // Skip events the athlete declined — they're not real commitments.
            .filter { $0.status != .canceled && !isDeclined($0) }
            .map {
                BusyWindow(
                    id: $0.eventIdentifier ?? UUID().uuidString,
                    title: $0.title ?? "Busy",
                    start: $0.startDate,
                    end: $0.endDate,
                    isAllDay: $0.isAllDay
                )
            }
            .sorted { $0.start < $1.start }
    }

    /// Per-day availability for each day in `[from, to]`. Days with no events get
    /// a zero-busy entry, so callers can render a complete range.
    func availability(from: Date, to: Date) -> [DayAvailability] {
        let cal = Calendar.current
        let startDay = cal.startOfDay(for: from)
        let endDay = cal.startOfDay(for: to)
        let windows = busyWindows(from: startDay, to: cal.date(byAdding: .day, value: 1, to: endDay) ?? to)

        var out: [DayAvailability] = []
        var day = startDay
        while day <= endDay {
            guard let dayEnd = cal.date(byAdding: .day, value: 1, to: day) else { break }
            let dayWindows = windows.filter { $0.start < dayEnd && $0.end > day }
            // Sum busy minutes clipped to the day; all-day events don't add minutes.
            let busy = dayWindows.filter { !$0.isAllDay }.reduce(0) { acc, w in
                let s = max(w.start, day)
                let e = min(w.end, dayEnd)
                return acc + max(0, Int(e.timeIntervalSince(s) / 60))
            }
            out.append(DayAvailability(
                date: day,
                busyMinutes: busy,
                allDay: dayWindows.contains { $0.isAllDay },
                windows: dayWindows
            ))
            day = dayEnd
        }
        return out
    }

    // MARK: - Helpers

    /// Whether the athlete (the calendar owner) declined this event.
    private func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.contains {
            $0.isCurrentUser && $0.participantStatus == .declined
        } ?? false
    }

    /// `#RRGGBB` for an EKCalendar color, so the picker can render its swatch.
    private static func hex(from cgColor: CGColor?) -> String {
        guard let comps = cgColor?.components, comps.count >= 3 else { return "#3478F6" }
        let r = Int((comps[0] * 255).rounded())
        let g = Int((comps[1] * 255).rounded())
        let b = Int((comps[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
