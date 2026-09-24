#if os(iOS)
import Foundation
import HealthKit
import WorkoutKit

// MARK: - Apple Watch (WorkoutKit) builder
//
// Translates the canonical normalized `workout_data` (the same shape Garmin
// consumes) into a WorkoutKit workout: swim/bike/run become a `CustomWorkout`
// (warmup/cooldown `WorkoutStep`s, `IntervalBlock`s of `IntervalStep`s,
// time/distance goals, HR/power/pace/speed/cadence range alerts); strength
// becomes a `SingleGoalWorkout`, since WorkoutKit can express no sets, reps or
// weights. Yoga/other return nil and the target reports a clear message.
// `CustomWorkout` traps for anything its initializer rejects, so membership is
// gated on `CustomWorkout.supportsActivity` and each alert on
// `CustomWorkout.supportsAlert` — an alert the activity can't carry (e.g. a pace
// alert on a swim) is dropped, keeping the goal and structure.

enum AppleWatchWorkoutBuilder {

    /// Build the schedulable workout from normalized `workout_data`, or nil if
    /// the sport can't be expressed on the watch at all.
    static func workout(from workoutData: [String: Any]) -> WorkoutPlan.Workout? {
        if SportFamily(sportKey: (workoutData["sport"] as? String) ?? "other") == .strength {
            // The exercises stay in the app — the watch gets the session's
            // planned length so it can be started and recorded.
            let activity = HKWorkoutActivityType.traditionalStrengthTraining
            let goal = durationGoal(workoutData)
            guard SingleGoalWorkout.supportsGoal(goal, activity: activity, location: .indoor) else { return nil }
            return .goal(SingleGoalWorkout(activity: activity, location: .indoor, goal: goal))
        }
        return customWorkout(from: workoutData).map { .custom($0) }
    }

    private static func durationGoal(_ workoutData: [String: Any]) -> WorkoutGoal {
        (workoutData["duration_minutes"] as? NSNumber).map { .time($0.doubleValue * 60, .seconds) } ?? .open
    }

    private static func customWorkout(from workoutData: [String: Any]) -> CustomWorkout? {
        let sportKey = (workoutData["sport"] as? String) ?? "other"
        guard let (activity, location) = activityType(for: sportKey),
              CustomWorkout.supportsActivity(activity) else { return nil }
        let family = SportFamily(sportKey: sportKey)
        let name = workoutData["name"] as? String ?? "Workout"
        let steps = workoutData["steps"] as? [[String: Any]] ?? []

        var warmup: WorkoutStep?
        var cooldown: WorkoutStep?
        var blocks: [IntervalBlock] = []

        if steps.isEmpty {
            // No structure — a single open/duration block.
            blocks = [IntervalBlock(steps: [IntervalStep(.work, goal: durationGoal(workoutData))], iterations: 1)]
        } else {
            for step in steps {
                let type = (step["type"] as? String) ?? "main"
                switch type {
                case "warmup":
                    warmup = WorkoutStep(goal: goal(from: step), alert: alert(from: step, family: family, activity: activity, location: location))
                case "cooldown":
                    cooldown = WorkoutStep(goal: goal(from: step), alert: alert(from: step, family: family, activity: activity, location: location))
                case "repeat":
                    let children = (step["repeat_steps"] as? [[String: Any]]) ?? []
                    let iterations = max(1, (step["repeat_count"] as? NSNumber)?.intValue ?? 4)
                    let intervalSteps = children.map { intervalStep(from: $0, family: family, activity: activity, location: location) }
                    if !intervalSteps.isEmpty {
                        blocks.append(IntervalBlock(steps: intervalSteps, iterations: iterations))
                    }
                default:
                    blocks.append(IntervalBlock(steps: [intervalStep(from: step, family: family, activity: activity, location: location)], iterations: 1))
                }
            }
        }

        return CustomWorkout(activity: activity, location: location, displayName: name,
                             warmup: warmup, blocks: blocks, cooldown: cooldown)
    }

    // MARK: - Step → IntervalStep

    private static func intervalStep(from step: [String: Any], family: SportFamily, activity: HKWorkoutActivityType, location: HKWorkoutSessionLocationType) -> IntervalStep {
        let type = (step["type"] as? String) ?? "main"
        let purpose: IntervalStep.Purpose = (type == "recovery" || type == "rest") ? .recovery : .work
        return IntervalStep(purpose, goal: goal(from: step), alert: alert(from: step, family: family, activity: activity, location: location))
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

    private static func alert(from step: [String: Any], family: SportFamily, activity: HKWorkoutActivityType, location: HKWorkoutSessionLocationType) -> (any WorkoutAlert)? {
        guard let type = step["target_type"] as? String, type != "no_target" else { return nil }
        let low = (step["target_low"] as? NSNumber)?.doubleValue
        let high = (step["target_high"] as? NSNumber)?.doubleValue
        guard let lo = low ?? high, let hi = high ?? low, lo > 0, hi > 0 else { return nil }
        let lower = min(lo, hi), upper = max(lo, hi)

        let built: (any WorkoutAlert)?
        switch type {
        case "heart_rate":
            built = HeartRateRangeAlert(target: perMinute(lower)...perMinute(upper))
        case "power":
            built = PowerRangeAlert(target: Measurement(value: lower, unit: .watts)...Measurement(value: upper, unit: .watts))
        case "cadence":
            built = CadenceRangeAlert(target: perMinute(lower)...perMinute(upper))
        case "speed":
            // km/h → m/s
            built = SpeedRangeAlert(target: Measurement(value: lower / 3.6, unit: .metersPerSecond)...Measurement(value: upper / 3.6, unit: .metersPerSecond), metric: .current)
        case "pace":
            // pace seconds → speed (m/s). Run: sec/km; swim: sec/100m. Faster pace =
            // smaller seconds = higher speed, so the bounds invert.
            let reference: Double = family == .swim ? 100 : 1000
            let speedLowerMS = reference / upper   // slowest pace → lowest speed
            let speedUpperMS = reference / lower
            built = SpeedRangeAlert(target: Measurement(value: speedLowerMS, unit: .metersPerSecond)...Measurement(value: speedUpperMS, unit: .metersPerSecond), metric: .current)
        default:
            built = nil
        }

        // WorkoutKit's `CustomWorkout` initializer *traps* (`unsupportedActivity`) on
        // an alert the activity can't carry — e.g. pace/speed alerts on a swim. Drop
        // the live alert rather than crash; the step keeps its goal and structure.
        guard let built, CustomWorkout.supportsAlert(built, activity: activity, location: location) else { return nil }
        return built
    }

    /// A per-minute frequency (bpm / rpm) as `Measurement<UnitFrequency>` — the type
    /// WorkoutKit's heart-rate and cadence range alerts expect (base unit is hertz).
    private static func perMinute(_ value: Double) -> Measurement<UnitFrequency> {
        Measurement(value: value, unit: UnitFrequency(symbol: "1/min", converter: UnitConverterLinear(coefficient: 1.0 / 60.0)))
    }

    // MARK: - Sport mapping

    /// Maps a sport family to its HealthKit activity type; other families return nil.
    private static func activityType(for sportKey: String) -> (HKWorkoutActivityType, HKWorkoutSessionLocationType)? {
        switch SportFamily(sportKey: sportKey) {
        case .run: return (.running, .outdoor)
        case .bike: return (.cycling, .outdoor)
        case .swim: return (.swimming, .indoor)
        default: return nil
        }
    }
}
#endif
