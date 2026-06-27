#if os(iOS)
import Foundation
import HealthKit
import WorkoutKit

// MARK: - Apple Watch (WorkoutKit) builder
//
// Translates the canonical normalized `workout_data` (the same shape Garmin
// consumes) into a WorkoutKit `CustomWorkout`: warmup/cooldown `WorkoutStep`s,
// `IntervalBlock`s (repeats) of `IntervalStep`s, time/distance goals, and
// HR/power/pace/speed/cadence range alerts. Sports WorkoutKit can't structure
// (strength/yoga/other) return nil — the target then reports a clear message
// rather than fuzzily mapping them.

enum AppleWatchWorkoutBuilder {

    /// Build a `CustomWorkout` from normalized `workout_data`, or nil if the sport
    /// can't be expressed as a structured WorkoutKit workout.
    static func customWorkout(from workoutData: [String: Any]) -> CustomWorkout? {
        let sportKey = (workoutData["sport"] as? String) ?? "other"
        guard let (activity, location) = activityType(for: sportKey) else { return nil }
        let family = SportFamily(sportKey: sportKey)
        let name = workoutData["name"] as? String ?? "Workout"
        let steps = workoutData["steps"] as? [[String: Any]] ?? []

        var warmup: WorkoutStep?
        var cooldown: WorkoutStep?
        var blocks: [IntervalBlock] = []

        if steps.isEmpty {
            // No structure — a single open/duration block.
            let goal: WorkoutGoal = (workoutData["duration_minutes"] as? NSNumber).map {
                .time($0.doubleValue * 60, .seconds)
            } ?? .open
            blocks = [IntervalBlock(steps: [IntervalStep(.work, goal: goal)], iterations: 1)]
        } else {
            for step in steps {
                let type = (step["type"] as? String) ?? "main"
                switch type {
                case "warmup":
                    warmup = WorkoutStep(goal: goal(from: step), alert: alert(from: step, family: family))
                case "cooldown":
                    cooldown = WorkoutStep(goal: goal(from: step), alert: alert(from: step, family: family))
                case "repeat":
                    let children = (step["repeat_steps"] as? [[String: Any]]) ?? []
                    let iterations = max(1, (step["repeat_count"] as? NSNumber)?.intValue ?? 4)
                    let intervalSteps = children.map { intervalStep(from: $0, family: family) }
                    if !intervalSteps.isEmpty {
                        blocks.append(IntervalBlock(steps: intervalSteps, iterations: iterations))
                    }
                default:
                    blocks.append(IntervalBlock(steps: [intervalStep(from: step, family: family)], iterations: 1))
                }
            }
        }

        return CustomWorkout(activity: activity, location: location, displayName: name,
                             warmup: warmup, blocks: blocks, cooldown: cooldown)
    }

    // MARK: - Step → IntervalStep

    private static func intervalStep(from step: [String: Any], family: SportFamily) -> IntervalStep {
        let type = (step["type"] as? String) ?? "main"
        let purpose: IntervalStep.Purpose = (type == "recovery" || type == "rest") ? .recovery : .work
        return IntervalStep(purpose, goal: goal(from: step), alert: alert(from: step, family: family))
    }

    // MARK: - Goal

    private static func goal(from step: [String: Any]) -> WorkoutGoal {
        if let meters = (step["distance_meters"] as? NSNumber)?.doubleValue, meters > 0 {
            return .distance(meters, .meters)
        }
        if let seconds = (step["duration_seconds"] as? NSNumber)?.doubleValue, seconds > 0 {
            return .time(seconds, .seconds)
        }
        return .open
    }

    // MARK: - Alert (intensity target → range alert)

    private static func alert(from step: [String: Any], family: SportFamily) -> (any WorkoutAlert)? {
        guard let type = step["target_type"] as? String, type != "no_target" else { return nil }
        let low = (step["target_low"] as? NSNumber)?.doubleValue
        let high = (step["target_high"] as? NSNumber)?.doubleValue
        guard let lo = low ?? high, let hi = high ?? low, lo > 0, hi > 0 else { return nil }
        let lower = min(lo, hi), upper = max(lo, hi)

        switch type {
        case "heart_rate":
            return HeartRateRangeAlert(target: perMinute(lower)...perMinute(upper))
        case "power":
            return PowerRangeAlert(target: Measurement(value: lower, unit: .watts)...Measurement(value: upper, unit: .watts))
        case "cadence":
            return CadenceRangeAlert(target: perMinute(lower)...perMinute(upper))
        case "speed":
            // km/h → m/s
            return SpeedRangeAlert(target: Measurement(value: lower / 3.6, unit: .metersPerSecond)...Measurement(value: upper / 3.6, unit: .metersPerSecond), metric: .current)
        case "pace":
            // pace seconds → speed (m/s). Run: sec/km; swim: sec/100m. Faster pace =
            // smaller seconds = higher speed, so the bounds invert.
            let reference: Double = family == .swim ? 100 : 1000
            let speedLowerMS = reference / upper   // slowest pace → lowest speed
            let speedUpperMS = reference / lower
            return SpeedRangeAlert(target: Measurement(value: speedLowerMS, unit: .metersPerSecond)...Measurement(value: speedUpperMS, unit: .metersPerSecond), metric: .current)
        default:
            return nil
        }
    }

    /// A per-minute frequency (bpm / rpm) as `Measurement<UnitFrequency>` — the type
    /// WorkoutKit's heart-rate and cadence range alerts expect (base unit is hertz).
    private static func perMinute(_ value: Double) -> Measurement<UnitFrequency> {
        Measurement(value: value, unit: UnitFrequency(symbol: "1/min", converter: UnitConverterLinear(coefficient: 1.0 / 60.0)))
    }

    // MARK: - Sport mapping

    /// WorkoutKit can only structure a subset of activities. Returns nil for ones
    /// it can't (strength/other), so the caller falls back with a clear note.
    private static func activityType(for sportKey: String) -> (HKWorkoutActivityType, HKWorkoutSessionLocationType)? {
        switch SportFamily(sportKey: sportKey) {
        case .run: return (.running, .outdoor)
        case .bike: return (.cycling, .outdoor)
        case .swim: return (.swimming, .indoor)  // pool length is prompted at start
        default: return nil
        }
    }
}
#endif
