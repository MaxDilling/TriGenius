//  TrainingPlanBanner.swift
//  The plan line under the Dashboard greeting: current period, week of season, and
//  the countdown to the next A event. Tapping it switches to the Plan tab.

import SwiftUI

struct TrainingPlanBanner: View {
    let plan: ATPPlan

    /// The week whose Mon–Sun span contains today; falls back to the first upcoming
    /// week (mirrors `ATPTabView.currentWeek`).
    private var currentWeek: ATPWeekPlan? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return plan.weeks.first {
            let end = cal.date(byAdding: .day, value: 6, to: $0.weekStart) ?? $0.weekStart
            return today >= $0.weekStart && today <= end
        } ?? plan.weeks.first { ($0.weeksToNextEvent ?? -1) >= 0 }
    }

    /// Position of the current week in the season (1-based) for the "Week X of Y" line.
    private var weekOfSeason: Int? {
        currentWeek.flatMap { wk in plan.weeks.firstIndex(where: { $0.weekStart == wk.weekStart }) }
            .map { $0 + 1 }
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
            }
            if let week = weekOfSeason {
                Text("Week \(week) of \(plan.weeks.count)")
            } else {
                Text("Tap to set up your plan")
            }
            if let event = targetEvent, let days = daysUntilEvent {
                Label(days >= 0 ? "\(event.name.isEmpty ? event.eventType.label : event.name) in \(days) days" : "past",
                      systemImage: "flag.fill")
            }
            Chevron()
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
