import ActivityKit
import AppIntents
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
            VStack(spacing: 12) {
                status.header
                HStack(alignment: .lastTextBaseline) {
                    status.total
                    Spacer(minLength: 8)
                    status.countdown
                }
            }
            .padding()
        } dynamicIsland: { context in
            let status = LiveStrengthStatus(state: context.state, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    status.total.padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    status.countdown.padding(.trailing, 8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    status.header
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

    private var summary: some View {
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
    private var clock: some View {
        Text(timerInterval: state.clockStart...Date.distantFuture, pauseTime: state.pausedAt, countsDown: false)
            .monospacedDigit()
    }

    /// Progress, the exercise and the button in one row.
    var header: some View {
        HStack(spacing: 12) {
            ring
            summary
            Spacer(minLength: 8)
            button
        }
    }

    var total: some View {
        VStack(alignment: .leading, spacing: 0) {
            clock.font(.title3.weight(.semibold))
            Text("Total time").font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    var countdown: some View {
        if let timer {
            Text(timerInterval: timer.range, countsDown: timer.countsDown)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120, alignment: .trailing)
        }
    }

    /// Sets done of all, the open part on a track that shows on a dark and a
    /// light Lock Screen alike.
    private var ring: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.2), lineWidth: 4)
            Circle()
                .trim(from: 0, to: Double(state.doneSets) / Double(max(1, state.totalSets)))
                .stroke(.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(state.doneSets)/\(state.totalSets)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .padding(5)
        }
        .frame(width: 44, height: 44)
    }

    /// The session's next step; once every set is done, the app, where the
    /// workout is ended.
    private var button: some View {
        Group {
            if state.phase == .allDone {
                Button(intent: LiveStrengthOpenIntent()) { buttonLabel }
            } else {
                Button(intent: LiveStrengthContinueIntent(step: state.step)) { buttonLabel }
            }
        }
        .buttonStyle(.plain)
    }

    private var buttonLabel: some View {
        Image(systemName: state.stepSymbol)
            .font(.title2.weight(.bold))
            .foregroundStyle(.tint)
            .frame(width: 50, height: 50)
            .background(.tint.opacity(0.25), in: .circle)
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
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: 56)
    }
}

// Stubs: the system performs both intents in the app.
extension LiveStrengthContinueIntent {
    func perform() async throws -> some IntentResult { .result() }
}

extension LiveStrengthOpenIntent {
    func perform() async throws -> some IntentResult { .result() }
}
