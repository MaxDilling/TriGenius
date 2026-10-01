import SwiftUI

// MARK: - Notifications page

struct NotificationSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            Section {
                NotificationSettingsSection(settings: settings)
            } header: {
                Text("Form alerts")
            } footer: {
                Text("Proactive alerts when your form (TSB) signals high fatigue or detraining. Evaluated on a background refresh.")
            }
            RemindersSection()
        }
        .navigationTitle("Notifications")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Notification Settings Section

/// Toggle for proactive background notifications. Enabling it requests
/// notification authorization and schedules the background refresh.
struct NotificationSettingsSection: View {
    @ObservedObject var settings: AppSettings
    @State private var statusMessage: String?

    var body: some View {
        Group {
            Toggle(isOn: Binding(
                get: { settings.proactiveNotifications },
                set: { newValue in
                    settings.proactiveNotifications = newValue
                    Task { await apply(newValue) }
                }
            )) {
                Label("Proactive notifications", systemImage: "bell.badge")
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func apply(_ enabled: Bool) async {
        guard enabled else {
            BackgroundCoordinator.shared.cancel()
            statusMessage = nil
            return
        }
        let granted = await NotificationCenterService.shared.requestAuthorization()
        if granted {
            BackgroundCoordinator.shared.schedule()
            statusMessage = "You'll get a proactive heads-up after the next background refresh."
        } else {
            settings.proactiveNotifications = false
            statusMessage = "Notifications are turned off for TriGenius — enable them in the Settings app."
        }
    }
}

// MARK: - Reminders Section

/// UI display metadata for a `ReminderKind`.
private extension ReminderKind {
    var title: String {
        switch self {
        case .checkIn: return "Check-in"
        case .weeklyReview: return "Weekly review"
        case .custom: return "Custom"
        case .todaysWorkout: return "Today's workout"
        case .sleepAdvice: return "Sleep advice"
        }
    }
    var systemImage: String {
        switch self {
        case .checkIn: return "bubble.left.and.bubble.right"
        case .weeklyReview: return "calendar.badge.clock"
        case .custom: return "bell"
        case .todaysWorkout: return "figure.run"
        case .sleepAdvice: return "bed.double"
        }
    }
}

/// Lists configurable reminders + quiet hours, bound to the shared `ReminderStore`.
/// Static reminders fire at their exact time via the OS; dynamic ones are composed
/// and delivered on a background refresh (timing is approximate).
struct RemindersSection: View {
    @ObservedObject private var store = ReminderStore.shared
    @State private var editing: ReminderRule?
    @State private var isAdding = false

    var body: some View {
        Section {
            // Quiet hours.
            QuietHoursRow(store: store)

            // Existing reminders.
            ForEach(store.rules) { rule in
                Button { editing = rule } label: { reminderRow(rule) }
                    .buttonStyle(.plain)
            }
            .onDelete { offsets in
                offsets.map { store.rules[$0].id }.forEach { store.delete(id: $0) }
                reconcile()
            }

            Button { isAdding = true } label: {
                Label("Add reminder", systemImage: "plus.circle")
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text("Schedule when TriGenius nudges you. Dynamic reminders (today's workout, sleep advice) are delivered around the chosen time on a background refresh, so they may arrive a little late.")
        }
        .sheet(isPresented: $isAdding) {
            ReminderEditorView(rule: nil) { saved in
                store.upsert(saved); reconcile()
            }
        }
        .sheet(item: $editing) { rule in
            ReminderEditorView(rule: rule) { saved in
                store.upsert(saved); reconcile()
            }
        }
    }

    @ViewBuilder
    private func reminderRow(_ rule: ReminderRule) -> some View {
        HStack {
            Image(systemName: rule.kind.systemImage)
                .frame(width: 24)
                .foregroundStyle(rule.enabled ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.kind == .custom ? (rule.message ?? rule.kind.title) : rule.kind.title)
                    .font(.body)
                    .lineLimit(1)
                Text("\(timeLabel(rule)) · \(weekdaysLabel(rule))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !rule.enabled {
                Text("Off").font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func timeLabel(_ rule: ReminderRule) -> String {
        String(format: "%02d:%02d", rule.hour, rule.minute)
    }

    private func weekdaysLabel(_ rule: ReminderRule) -> String {
        guard !rule.weekdays.isEmpty else { return "Every day" }
        let short = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return rule.weekdays.sorted().map { short[$0] }.joined(separator: " ")
    }

    private func reconcile() {
        Task {
            await NotificationCenterService.shared.requestAuthorization()
            await ReminderScheduler.shared.reconcile()
        }
    }
}

/// A toggle + two time pickers for the quiet-hours window.
private struct QuietHoursRow: View {
    @ObservedObject var store: ReminderStore

    private var isOn: Bool { store.quietStartMinute != nil && store.quietEndMinute != nil }

    var body: some View {
        Toggle(isOn: Binding(
            get: { isOn },
            set: { on in
                if on { store.setQuietHours(start: 22 * 60, end: 7 * 60) }
                else { store.setQuietHours(start: nil, end: nil) }
            }
        )) {
            Label("Quiet hours", systemImage: "moon")
        }

        if isOn {
            DatePicker("From", selection: Binding(
                get: { Self.date(fromMinutes: store.quietStartMinute ?? 0) },
                set: { store.setQuietHours(start: Self.minutes(from: $0), end: store.quietEndMinute) }
            ), displayedComponents: .hourAndMinute)

            DatePicker("To", selection: Binding(
                get: { Self.date(fromMinutes: store.quietEndMinute ?? 0) },
                set: { store.setQuietHours(start: store.quietStartMinute, end: Self.minutes(from: $0)) }
            ), displayedComponents: .hourAndMinute)
        }
    }

    static func date(fromMinutes m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }
    static func minutes(from date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

/// Create/edit sheet for a single reminder.
struct ReminderEditorView: View {
    let rule: ReminderRule?
    let onSave: (ReminderRule) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: ReminderKind
    @State private var time: Date
    @State private var weekdays: Set<Int>
    @State private var enabled: Bool
    @State private var message: String

    private let weekdayOrder = [2, 3, 4, 5, 6, 7, 1] // Mon…Sun
    private let weekdayShort = ["", "S", "M", "T", "W", "T", "F", "S"]

    init(rule: ReminderRule?, onSave: @escaping (ReminderRule) -> Void) {
        self.rule = rule
        self.onSave = onSave
        _kind = State(initialValue: rule?.kind ?? .checkIn)
        _time = State(initialValue: QuietHoursRow.date(fromMinutes: (rule?.hour ?? 8) * 60 + (rule?.minute ?? 0)))
        _weekdays = State(initialValue: Set(rule?.weekdays ?? []))
        _enabled = State(initialValue: rule?.enabled ?? true)
        _message = State(initialValue: rule?.message ?? "")
    }

    private var isValid: Bool {
        kind != .custom || !message.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(ReminderKind.allCases, id: \.self) { k in
                            Label(k.title, systemImage: k.systemImage).tag(k)
                        }
                    }
                    if kind == .custom {
                        TextField("Message", text: $message, axis: .vertical)
                    }
                } footer: {
                    Text(kind.isDynamic
                         ? "Composed from your current data and delivered around this time on a background refresh."
                         : "Fires at the exact time, even when the app is closed.")
                }

                Section {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    Toggle("Enabled", isOn: $enabled)
                }

                Section {
                    HStack {
                        ForEach(Array(weekdayOrder.enumerated()), id: \.offset) { _, wd in
                            let on = weekdays.contains(wd)
                            Button {
                                if on { weekdays.remove(wd) } else { weekdays.insert(wd) }
                            } label: {
                                Text(weekdayShort[wd])
                                    .font(.caption.bold())
                                    .frame(maxWidth: .infinity, minHeight: 34)
                                    .background(on ? Color.accentColor : Color.secondary.opacity(0.15))
                                    .foregroundStyle(on ? .white : .primary)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Repeat")
                } footer: {
                    Text(weekdays.isEmpty ? "No days selected → repeats every day." : "")
                }
            }
            .navigationTitle(rule == nil ? "New Reminder" : "Edit Reminder")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!isValid)
                }
            }
        }
    }

    private func save() {
        let m = QuietHoursRow.minutes(from: time)
        let saved = ReminderRule(
            id: rule?.id ?? UUID().uuidString,
            kind: kind,
            enabled: enabled,
            hour: m / 60,
            minute: m % 60,
            weekdays: weekdays.sorted(),
            message: kind == .custom ? message : nil
        )
        onSave(saved)
        dismiss()
    }
}

// MARK: - Reminder Test View

/// Developer screen to exercise the reminder pipeline without waiting for the
/// real schedule or a system background refresh.
struct ReminderTestView: View {
    @ObservedObject private var store = ReminderStore.shared
    @State private var status: String?
    @State private var dynamicPreviews: [ReminderKind: String] = [:]
    @State private var pending: [String] = []
    @State private var isBusy = false

    var body: some View {
        Form {
            Section {
                Button {
                    run { granted in status = granted ? "Notifications authorized." : "Authorization denied — enable TriGenius in the Settings app." }
                } label: { Label("Request authorization", systemImage: "checkmark.shield") }

                Button {
                    run { _ in
                        let ok = await NotificationCenterService.shared.post(
                            title: "TriGenius — test",
                            body: "This is an immediate test reminder.",
                            identifier: "trigenius.reminder.test.\(UUID().uuidString)")
                        status = ok ? "Sent an immediate test notification." : "Couldn't send — check authorization."
                    }
                } label: { Label("Send test notification now", systemImage: "paperplane") }

                Button {
                    run { _ in
                        let ok = await NotificationCenterService.shared.scheduleTest(after: 10)
                        status = ok ? "Scheduled a test for 10s from now — background the app to see it." : "Couldn't schedule — check authorization."
                    }
                } label: { Label("Schedule test in 10s", systemImage: "clock.badge") }
            } header: {
                Text("Delivery")
            } footer: {
                Text("Verifies notification permission and that the OS delivers TriGenius notifications.")
            }

            Section {
                ForEach([ReminderKind.todaysWorkout, .sleepAdvice], id: \.self) { kind in
                    Button {
                        run { _ in
                            let body = await BackgroundCoordinator.shared.sendDynamicReminderTest(kind)
                            dynamicPreviews[kind] = body ?? "(nothing to report right now)"
                            status = body == nil ? "\(label(kind)): nothing to report — not sent." : "\(label(kind)): sent."
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Compose & send \(label(kind))", systemImage: kind.systemImage)
                            if let preview = dynamicPreviews[kind] {
                                Text(preview).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Dynamic reminders")
            } footer: {
                Text("Composes the body from your current data and delivers it immediately, ignoring the once-per-day limit.")
            }

            Section {
                Button {
                    run { _ in
                        await BackgroundCoordinator.shared.runProactiveCheck()
                        status = "Ran the full background check (sync + proactive digest + due dynamic reminders)."
                    }
                } label: { Label("Run background check now", systemImage: "arrow.triangle.2.circlepath") }
            } footer: {
                Text("Simulates the periodic background refresh. Gated by the Proactive notifications toggle and quiet hours, just like the real run.")
            }

            Section {
                Button {
                    run { _ in
                        await NotificationCenterService.shared.requestAuthorization()
                        await ReminderScheduler.shared.reconcile()
                        pending = await ReminderScheduler.shared.pendingReminderBodies()
                        status = "Reconciled \(pending.count) OS-scheduled reminder(s)."
                    }
                } label: { Label("Reconcile & list scheduled", systemImage: "list.bullet.rectangle") }

                if pending.isEmpty {
                    Text("No static reminders scheduled with the OS.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(pending, id: \.self) { Text($0).font(.caption) }
                }
            } header: {
                Text("Scheduled (static) reminders")
            }

            if let status {
                Section {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Test Reminders")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { pending = await ReminderScheduler.shared.pendingReminderBodies() }
        .disabled(isBusy)
    }

    private func label(_ kind: ReminderKind) -> String {
        kind == .todaysWorkout ? "today's workout" : "sleep advice"
    }

    /// Run an async action, requesting authorization first and toggling busy.
    private func run(_ action: @escaping (Bool) async -> Void) {
        isBusy = true
        Task {
            let granted = await NotificationCenterService.shared.requestAuthorization()
            await action(granted)
            isBusy = false
        }
    }
}
