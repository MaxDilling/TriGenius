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

        for step in steps {
            let stepTypeStr = Coerce.token(step["type"] as? String, default: "interval")
            let stepType = GarminMappings.workoutStepTypes[stepTypeStr] ?? GarminMappings.workoutStepTypes["interval"]!

            if stepTypeStr == "repeat" {
                var repeatSteps: [[String: Any]] = []
                var childOrder = 1
                for child in step["repeat_steps"] as? [[String: Any]] ?? [] {
                    let childTypeStr = Coerce.token(child["type"] as? String, default: "interval")
                    let childType = GarminMappings.workoutStepTypes[childTypeStr] ?? GarminMappings.workoutStepTypes["interval"]!
                    let childEnd = Coerce.token(child["end_condition"] as? String, default: "time")
                    var childStep = createStep(
                        order: stepOrder + childOrder,
                        stepTypeKey: childType.key, stepTypeId: childType.id, sport: sport,
                        endCondition: childEnd,
                        endValue: Coerce.double(child["distance_meters"]) ?? Coerce.double(child["duration_seconds"]) ?? 60,
                        targetType: child["target_type"] as? String,
                        targetLow: Coerce.double(child["target_low"]), targetHigh: Coerce.double(child["target_high"]),
                        stroke: child["stroke"] as? String
                    )
                    childStep["childStepId"] = 1
                    repeatSteps.append(childStep)
                    childOrder += 1
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

        // Pace targets given as sec/km are converted to m/s for Garmin.
        if targetType == "pace", let low = targetLow, let high = targetHigh, low > 10, high > 10 {
            convertedLow = 1000.0 / high
            convertedHigh = 1000.0 / low
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
