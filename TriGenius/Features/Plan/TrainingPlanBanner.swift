//  TrainingPlanBanner.swift
//  The tappable phase banner shown at the top of the Dashboard: current phase +
//  week-of-plan on the left, target event + countdown on the right. Tapping it
//  pushes the full training overview (PlanView).

import SwiftUI

struct TrainingPlanBanner: View {
    let plan: TrainingPlan

    /// Whether there's enough to show a meaningful banner.
    static func hasData(_ plan: TrainingPlan) -> Bool {
        plan.targetEvent != nil || !plan.phases.isEmpty
    }

    private var currentPhase: Phase? { plan.phase() }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            phaseColumn
            if plan.targetEvent != nil {
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

    // MARK: Phase (left)

    @ViewBuilder private var phaseColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let phase = currentPhase {
                HStack(spacing: 6) {
                    Circle().fill(phase.name.color).frame(width: 8, height: 8)
                    Text("\(phase.name.displayName.uppercased()) PHASE")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(phase.name.color)
                }
            } else {
                Text("TRAINING PLAN")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            if let week = plan.currentWeek(), let total = plan.totalWeeks {
                HStack(spacing: 5) {
                    Text("Week \(week)").font(.title3.bold())
                    Text("of \(total)").font(.subheadline).foregroundStyle(.secondary)
                }
            } else if currentPhase == nil {
                Text("Tap to set up your plan")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Event (right)

    @ViewBuilder private var eventColumn: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let event = plan.targetEvent {
                Text(event)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let days = plan.daysUntilEvent() {
                HStack(spacing: 5) {
                    Image(systemName: "flag.fill").font(.caption)
                    Text(days >= 0 ? "\(days) days" : "past")
                        .font(.title3.bold())
                }
            }
        }
    }
}
