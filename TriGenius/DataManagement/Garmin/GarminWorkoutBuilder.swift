import Foundation

// MARK: - Garmin Workout Payload Builder
//
// Ported from TriGenius_python/garmin/workout_payloads.py. Translates an
// already-normalized workout model (see WorkoutNormalizer) into the JSON payload
// Garmin's workout-service expects. All defaulting, step synthesis and target-band
// expansion happen upstream in WorkoutNormalizer; this type is Garmin wire-format
// only (sport/step/target lookups via GarminMappings + the sec/km → m/s pace
// conversion).

nonisolated enum GarminWorkoutBuilder {

    static func buildWorkoutJSON(_ workoutData: [String: Any], sportType: GarminMappings.SportType, sport: String) -> [String: Any] {
        let name = workoutData["name"] as? String ?? "Workout"
        let description = workoutData["description"] as? String ?? ""
        // duration and distance are both optional — a workout may target one, the
        // other, or carry explicit steps.
        let durationMinutes = (workoutData["duration_minutes"] as? NSNumber)?.intValue
        let distanceMeters = (workoutData["distance_meters"] as? NSNumber)?.doubleValue
        let steps = workoutData["steps"] as? [[String: Any]] ?? []

        var workoutJSON: [String: Any] = [
            "workoutName": name,
            "description": description,
            "sportType": sportType.dict
        ]
        if let durationMinutes { workoutJSON["estimatedDurationInSecs"] = durationMinutes * 60 }
        if let distanceMeters { workoutJSON["estimatedDistanceInMeters"] = distanceMeters }

        var poolLengthUnit: [String: Any]?
        if WorkoutNormalizer.swimSportKeys.contains(sport) {
            let poolLength = (workoutData["pool_length"] as? NSNumber)?.doubleValue ?? 50
            poolLengthUnit = ["unitId": 1, "unitKey": "meter", "factor": 100.0]
            workoutJSON["poolLength"] = poolLength
            workoutJSON["poolLengthUnit"] = poolLengthUnit
        }

        // Steps arrive already normalized by WorkoutNormalizer (always a non-empty,
        // explicit list with resolved end conditions and expanded target bands), so
        // the builder only translates them to Garmin's wire format.
        let workoutSteps = buildStructuredSteps(steps, sport: sport)

        var segment: [String: Any] = [
            "segmentOrder": 1,
            "sportType": sportType.dict,
            "workoutSteps": workoutSteps
        ]
        if WorkoutNormalizer.swimSportKeys.contains(sport) {
            segment["poolLength"] = workoutJSON["poolLength"]
            segment["poolLengthUnit"] = poolLengthUnit as Any
        }
        workoutJSON["workoutSegments"] = [segment]
        return workoutJSON
    }

    static func buildStructuredSteps(_ steps: [[String: Any]], sport: String) -> [[String: Any]] {
        var workoutSteps: [[String: Any]] = []
        var stepOrder = 1

        for (index, step) in steps.enumerated() {
            let stepTypeStr = Coerce.token(step["type"] as? String, default: "interval")
            let stepType = GarminMappings.workoutStepTypes[stepTypeStr] ?? GarminMappings.workoutStepTypes["interval"]!

            if stepTypeStr == "exercise" {
                var exercise = exerciseSteps(step, startOrder: stepOrder, sport: sport)
                if let rest = StrengthSets.restAfter(steps, at: index) {
                    exercise.append(restStep(rest, order: stepOrder + exercise.count, sport: sport))
                }
                workoutSteps.append(contentsOf: exercise)
                stepOrder += exercise.count
                continue
            }

            if stepTypeStr == "repeat" {
                var repeatSteps: [[String: Any]] = []
                for child in step["repeat_steps"] as? [[String: Any]] ?? [] {
                    let childTypeStr = Coerce.token(child["type"] as? String, default: "interval")
                    if childTypeStr == "exercise" {
                        repeatSteps.append(contentsOf: exerciseSteps(child, startOrder: stepOrder + repeatSteps.count + 1, sport: sport)
                            .map { var s = $0; s["childStepId"] = 1; return s })
                        continue
                    }
                    let childType = GarminMappings.workoutStepTypes[childTypeStr] ?? GarminMappings.workoutStepTypes["interval"]!
                    let childEnd = Coerce.token(child["end_condition"] as? String, default: "time")
                    var childStep = createStep(
                        order: stepOrder + repeatSteps.count + 1,
                        stepTypeKey: childType.key, stepTypeId: childType.id, sport: sport,
                        endCondition: childEnd,
                        endValue: Coerce.double(child["distance_meters"]) ?? Coerce.double(child["duration_seconds"]) ?? 60,
                        targetType: child["target_type"] as? String,
                        targetLow: Coerce.double(child["target_low"]), targetHigh: Coerce.double(child["target_high"]),
                        stroke: child["stroke"] as? String
                    )
                    childStep["childStepId"] = 1
                    repeatSteps.append(childStep)
                }
                // A circuit's rest lives on the block (its children are all
                // exercises, so there is no rest-kind sibling step to carry it).
                if let roundRest = Coerce.double(step["rest_between_rounds_seconds"]), roundRest > 0,
                   repeatSteps.contains(where: { $0["exerciseName"] != nil }) {
                    let rest = GarminMappings.workoutStepTypes["rest"]!
                    var restStep = createStep(order: stepOrder + repeatSteps.count + 1, stepTypeKey: rest.key,
                                              stepTypeId: rest.id, sport: sport, endCondition: "time", endValue: roundRest)
                    restStep["childStepId"] = 1
                    repeatSteps.append(restStep)
                }
                let iterations = (step["repeat_count"] as? NSNumber)?.intValue ?? 4
                workoutSteps.append([
                    "type": "RepeatGroupDTO",
                    "stepId": NSNull(),
                    "stepOrder": stepOrder,
                    "stepType": stepType.dict,
                    "childStepId": 1,
                    "numberOfIterations": iterations,
                    "workoutSteps": repeatSteps,
                    "endConditionValue": Double(iterations),
                    "endCondition": ["conditionTypeId": 7, "conditionTypeKey": "iterations", "displayOrder": 7, "displayable": false],
                    "skipLastRestStep": step["skip_last_rest"] as? Bool ?? true,
                    "smartRepeat": false
                ])
                stepOrder += repeatSteps.count + 1
                continue
            }

            let endCondition = Coerce.token(step["end_condition"] as? String, default: "time")
            workoutSteps.append(createStep(
                order: stepOrder,
                stepTypeKey: stepType.key, stepTypeId: stepType.id, sport: sport,
                endCondition: endCondition,
                endValue: Coerce.double(step["distance_meters"]) ?? Coerce.double(step["duration_seconds"]) ?? 60,
                targetType: step["target_type"] as? String,
                targetLow: Coerce.double(step["target_low"]), targetHigh: Coerce.double(step["target_high"]),
                stroke: step["stroke"] as? String
            ))
            stepOrder += 1
        }
        return workoutSteps
    }

    // MARK: - Exercise (strength) steps

    /// Garmin models a strength exercise as one step per set: a reps- (or, for a
    /// hold, time-) ended `interval` naming the exercise from Garmin's own
    /// catalog, with a `rest` step between sets — the watch asks for the counted
    /// reps at each rest. `exercise_id` resolves through
    /// `ExerciseLibrary` to that catalog's `category`/`exerciseName`; an exercise
    /// Garmin has no entry for (and a free-typed custom one) goes over unnamed
    /// with the athlete's own name in the step description — naming a
    /// neighbouring exercise instead would put a different movement on the watch.
    private static func exerciseSteps(_ step: [String: Any], startOrder: Int, sport: String) -> [[String: Any]] {
        let sets = step["sets"] as? [[String: Any]] ?? []
        let exercise = (step["exercise_id"] as? String).flatMap { ExerciseLibrary.find(id: $0) }
        let name = (step["exercise_name"] as? String) ?? exercise?.name ?? "Exercise"
        let interval = GarminMappings.workoutStepTypes["interval"]!

        var out: [[String: Any]] = []
        for (index, set) in sets.enumerated() {
            let reps = Coerce.double(set["reps"])
            var work = createStep(order: startOrder + out.count, stepTypeKey: interval.key, stepTypeId: interval.id,
                                  sport: sport, endCondition: reps != nil ? "reps" : "time",
                                  endValue: reps ?? Coerce.double(set["duration_seconds"]) ?? 30)
            work["category"] = exercise?.garminCategory as Any? ?? NSNull()
            work["exerciseName"] = exercise?.garminName as Any? ?? NSNull()
            work["description"] = name
            if let kg = Coerce.double(set["weight_kg"]), kg > 0 {
                work["weightValue"] = kg
                work["weightUnit"] = kilogramUnit
            }
            out.append(work)
            if index < sets.count - 1, let rest = StrengthSets.rest(ofSet: set), rest != .timed(seconds: 0) {
                out.append(restStep(rest, order: startOrder + out.count, sport: sport))
            }
        }
        return out
    }

    private static func restStep(_ rest: StrengthSets.Rest, order: Int, sport: String) -> [String: Any] {
        let type = GarminMappings.workoutStepTypes["rest"]!
        return switch rest {
        case .timed(let seconds):
            createStep(order: order, stepTypeKey: type.key, stepTypeId: type.id, sport: sport, endValue: seconds)
        case .lapButton:
            createStep(order: order, stepTypeKey: type.key, stepTypeId: type.id, sport: sport, endCondition: "lap_button")
        }
    }

    /// The unit object Garmin pairs with a weighted strength step; `weightValue`
    /// itself is in kilograms (confirmed against a Connect-authored workout).
    nonisolated(unsafe) private static let kilogramUnit: [String: Any] = ["unitId": 8, "unitKey": "kilogram", "factor": 1000.0]

    static func createStep(
        order: Int,
        stepTypeKey: String,
        stepTypeId: Int,
        sport: String,
        endCondition: String = "time",
        endValue: Double = 300,
        targetType: String? = nil,
        targetLow: Double? = nil,
        targetHigh: Double? = nil,
        stroke: String? = nil
    ) -> [String: Any] {
        var convertedLow = targetLow
        var convertedHigh = targetHigh

        // Pace targets (sec/100m for swim, sec/km otherwise) are converted to m/s
        // for Garmin. Faster pace = fewer seconds = higher speed, so bounds invert.
        if targetType == "pace", let low = targetLow, let high = targetHigh, low > 10, high > 10 {
            let reference = SportFamily(sportKey: sport) == .swim ? 100.0 : 1000.0
            convertedLow = reference / high
            convertedHigh = reference / low
        }

        // Speed targets given as km/h are converted to m/s for Garmin.
        if targetType == "speed", let low = targetLow, let high = targetHigh, low > 0, high > 0 {
            convertedLow = low / 3.6
            convertedHigh = high / 3.6
        }

        var step: [String: Any] = [
            "type": "ExecutableStepDTO",
            "stepId": NSNull(),
            "stepOrder": order,
            "stepType": ["stepTypeId": stepTypeId, "stepTypeKey": stepTypeKey, "displayOrder": stepTypeId],
            "childStepId": NSNull(),
            "description": NSNull(),
            "endCondition": GarminMappings.workoutEndConditions[endCondition] ?? GarminMappings.workoutEndConditions["time"]!,
            "endConditionValue": endValue,
            "targetType": GarminMappings.workoutTargetTypes[targetType ?? "no_target"] ?? GarminMappings.workoutTargetTypes["no_target"]!,
            "targetValueOne": convertedLow as Any? ?? NSNull(),
            "targetValueTwo": convertedHigh as Any? ?? NSNull(),
            "targetValueUnit": NSNull(),
            "zoneNumber": NSNull()
        ]

        if endCondition == "distance" {
            step["preferredEndConditionUnit"] = ["unitId": 1, "unitKey": "meter", "factor": 100.0]
        }

        if WorkoutNormalizer.swimSportKeys.contains(sport) {
            if stepTypeKey == "rest" {
                step["strokeType"] = GarminMappings.workoutStrokeNone
            } else {
                let strokeKey = stroke.map { Coerce.token($0) }
                step["strokeType"] = GarminMappings.workoutStrokes[strokeKey ?? "free"] ?? GarminMappings.workoutStrokes["free"]!
            }
            step["equipmentType"] = ["equipmentTypeId": 0, "equipmentTypeKey": NSNull(), "displayOrder": 0]
        }

        return step
    }
}
