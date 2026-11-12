import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Live strength Live Activity
//
// The running strength session on the Lock Screen and in the Dynamic Island,
// drawn from `LiveStrengthAttributes`. Rest, hold and the workout clock run on
// their own; a rest or hold that ran out while the app was suspended leaves the
// content stale, and it reads as over until the app updates it.

struct LiveStrengthLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveStrengthAttributes.self) { context in
            let status = LiveStrengthStatus(state: context.state, isStale: context.isStale)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(context.attributes.planName, systemImage: "dumbbell.fill")
                    Spacer()
                    status.clock
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                HStack {
                    status.summary
                    Spacer(minLength: 8)
                    status.countdown(size: 40)
                }
                status.progress
            }
            .padding()
        } dynamicIsland: { context in
            let status = LiveStrengthStatus(state: context.state, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    status.summary.padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    status.countdown(size: 32)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    status.progress
                }
            } compactLeading: {
                Image(systemName: "dumbbell.fill").foregroundStyle(.tint)
            } compactTrailing: {
                status.compactTimer
            } minimal: {
                status.compactTimer
            }
        }
    }
}

private struct LiveStrengthStatus {
    let state: LiveStrengthAttributes.ContentState
    let isStale: Bool

    /// The running rest or hold, and whether it counts down — an untimed rest
    /// counts up.
    private var timer: (range: ClosedRange<Date>, countsDown: Bool)? {
        switch state.phase {
        case .resting(let since, let until?) where !isStale, .holding(let since, let until) where !isStale:
            (since...until, true)
        case .resting(let since, nil):
            (since...Date.distantFuture, false)
        default:
            nil
        }
    }

    /// Nil while a set is under way — the exercise speaks for itself.
    private var caption: String? {
        switch state.phase {
        case .working: nil
        case .holding: isStale ? "Hold done" : "Hold"
        case .resting: isStale ? "Rest over · up next" : "Rest · up next"
        case .paused: "Paused"
        case .allDone: "All sets done"
        }
    }

    var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let caption {
                Text(caption).font(.caption.weight(.semibold)).foregroundStyle(.tint)
            }
            Text(state.title).font(.headline).lineLimit(1)
            if !state.detail.isEmpty {
                Text(state.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// The workout's active time, standing still while paused.
    var clock: some View {
        Text(timerInterval: state.clockStart...Date.distantFuture, pauseTime: state.pausedAt, countsDown: false)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }

    @ViewBuilder
    func countdown(size: CGFloat) -> some View {
        if let timer {
            Text(timerInterval: timer.range, countsDown: timer.countsDown)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: size * 3, alignment: .trailing)
        }
    }

    /// The rest or hold when one runs, else the workout clock.
    @ViewBuilder
    var compactTimer: some View {
        Group {
            if let timer {
                Text(timerInterval: timer.range, countsDown: timer.countsDown)
            } else {
                clock
            }
        }
        .monospacedDigit()
        .frame(maxWidth: 56)
    }

    var progress: some View {
        ProgressView(value: Double(state.doneSets), total: Double(max(1, state.totalSets)))
            .tint(.green)
    }
}
