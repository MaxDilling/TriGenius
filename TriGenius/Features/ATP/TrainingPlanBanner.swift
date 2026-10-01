//  TrainingPlanBanner.swift
//  The plan line under the Dashboard greeting: current period and
//  the countdown to the next A event. Tapping it opens the Plan page.

import SwiftUI

struct TrainingPlanBanner: View {
    let plan: ATPPlan

    /// The week whose Mon–Sun span contains today; falls back to the first upcoming
    /// week (mirrors `ATPView.currentWeek`).
    private var currentWeek: ATPWeekPlan? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return plan.weeks.first {
            let end = cal.date(byAdding: .day, value: 6, to: $0.weekStart) ?? $0.weekStart
            return today >= $0.weekStart && today <= end
        } ?? plan.weeks.first { ($0.weeksToNextEvent ?? -1) >= 0 }
    }

    /// The next upcoming A event (else the last A on the plan), the taper anchor.
    private var targetEvent: ATPEventInput? {
        let today = Calendar.current.startOfDay(for: Date())
        let aEvents = plan.events.filter { $0.priority == .a }
        return aEvents.first { $0.date >= today } ?? aEvents.last
    }

    private var daysUntilEvent: Int? {
        targetEvent.map {
            Calendar.current.dateComponents([.day],
                from: Calendar.current.startOfDay(for: Date()),
                to: Calendar.current.startOfDay(for: $0.date)).day ?? 0
        }
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            if let period = currentWeek?.period {
                Circle().fill(period.tint).frame(width: 8, height: 8)
                Text(period.label).fontWeight(.semibold).foregroundStyle(period.tint)
            } else {
                Text("Tap to set up your plan")
            }
            if let event = targetEvent, let days = daysUntilEvent {
                // Only the name gives way on a narrow screen — the countdown stays whole.
                Label(event.name.isEmpty ? event.eventType.label : event.name, systemImage: "flag.fill")
                    .layoutPriority(-1)
                Text(days >= 0 ? "· \(days) d" : "· past")
            }
            Chevron()
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
