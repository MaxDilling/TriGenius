//  TrainingPlanBanner.swift
//  The tappable ATP banner shown at the top of the Dashboard: current period +
//  week-of-season on the left, next A event + countdown on the right. Tapping it
//  switches to the Plan tab (the full season overview / ATPTabView).

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
        HStack(alignment: .center, spacing: 16) {
            periodColumn
            if targetEvent != nil {
                Divider().frame(maxHeight: 44)
                eventColumn
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .dashCard()
    }

    // MARK: Period (left)

    @ViewBuilder private var periodColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let period = currentWeek?.period {
                HStack(spacing: 6) {
                    Circle().fill(period.tint).frame(width: 8, height: 8)
                    Text("\(period.label.uppercased()) PHASE")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(period.tint)
                }
            } else {
                Text("TRAINING PLAN")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            if let week = weekOfSeason {
                HStack(spacing: 5) {
                    Text("Week \(week)").font(.title3.bold())
                    Text("of \(plan.weeks.count)").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Text("Tap to set up your plan")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Event (right)

    @ViewBuilder private var eventColumn: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let event = targetEvent {
                Text(event.name.isEmpty ? event.eventType.label : event.name)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let days = daysUntilEvent {
                HStack(spacing: 5) {
                    Image(systemName: "flag.fill").font(.caption)
                    Text(days >= 0 ? "\(days) days" : "past")
                        .font(.title3.bold())
                }
            }
        }
    }
}
