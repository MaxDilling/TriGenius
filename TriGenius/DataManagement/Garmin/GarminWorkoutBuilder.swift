import Foundation

// MARK: - Garmin Workout Payload Builder
//
// Ported from TriGenius_python/garmin/workout_payloads.py. Builds the JSON
// payload Garmin's workout-service expects from the LLM's workout definition.

nonisolated enum GarminWorkoutBuilder {

    static let swimSportKeys: Set<String> = ["swimming", "swim", "pool_swimming", "lap_swimming"]

    static func buildWorkoutJSON(_ workoutData: [String: Any], sportType: GarminMappings.SportType, sport: String) -> [String: Any] {
        let name = workoutData["name"] as? String ?? "Workout"
        let description = workoutData["description"] as? String ?? ""
        let durationMinutes = (workoutData["duration_minutes"] as? NSNumber)?.intValue ?? 60
        let durationSecs = durationMinutes * 60
        let distanceMeters = (workoutData["distance_meters"] as? NSNumber)?.doubleValue
        let steps = workoutData["steps"] as? [[String: Any]] ?? []

        var workoutJSON: [String: Any] = [
            "workoutName": name,
            "description": description,
            "sportType": sportType.dict,
            "estimatedDurationInSecs": durationSecs
        ]

        var poolLengthUnit: [String: Any]?
        if swimSportKeys.contains(sport) {
            let poolLength = (workoutData["pool_length"] as? NSNumber)?.doubleValue ?? 25
            poolLengthUnit = ["unitId": 1, "unitKey": "meter", "factor": 100.0]
            workoutJSON["poolLength"] = poolLength
            workoutJSON["poolLengthUnit"] = poolLengthUnit
            if let distanceMeters { workoutJSON["estimatedDistanceInMeters"] = distanceMeters }
        }

        let workoutSteps: [[String: Any]]
        if !steps.isEmpty {
            workoutSteps = buildStructuredSteps(steps, sport: sport)
        } else {
            workoutSteps = buildSimpleSteps(workoutData, sport: sport, durationSecs: durationSecs, distanceMeters: distanceMeters)
        }

        var segment: [String: Any] = [
            "segmentOrder": 1,
            "sportType": sportType.dict,
            "workoutSteps": workoutSteps
        ]
        if swimSportKeys.contains(sport) {
            segment["poolLength"] = workoutJSON["poolLength"]
            segment["poolLengthUnit"] = poolLengthUnit as Any
        }
        workoutJSON["workoutSegments"] = [segment]
        return workoutJSON
    }

    static func buildSimpleSteps(_ workoutData: [String: Any], sport: String, durationSecs: Int, distanceMeters: Double?) -> [[String: Any]] {
        var steps: [[String: Any]] = []
        var stepOrder = 1
        var remaining = durationSecs
        let includeWarmup = workoutData["include_warmup"] as? Bool ?? true
        let includeCooldown = workoutData["include_cooldown"] as? Bool ?? true
        let defaultStroke = workoutData["stroke"] as? String ?? "free"

        if includeWarmup && remaining >= 600 {
            let warmupSecs = min(Double(remaining) * 0.1, 300)
            steps.append(createStep(order: stepOrder, stepTypeKey: "warmup", stepTypeId: 1, sport: sport,
                                    endCondition: "time", endValue: warmupSecs, stroke: defaultStroke))
            stepOrder += 1
            remaining -= Int(warmupSecs)
        }

        var cooldownSecs = 0.0
        if includeCooldown && remaining >= 600 {
            cooldownSecs = min(Double(remaining) * 0.1, 300)
            remaining -= Int(cooldownSecs)
        }

        if let distanceMeters, swimSportKeys.contains(sport) {
            steps.append(createStep(order: stepOrder, stepTypeKey: "interval", stepTypeId: 3, sport: sport,
                                    endCondition: "distance", endValue: distanceMeters, stroke: defaultStroke))
        } else {
            steps.append(createStep(order: stepOrder, stepTypeKey: "interval", stepTypeId: 3, sport: sport,
                                    endCondition: "time", endValue: Double(remaining), stroke: defaultStroke))
        }
        stepOrder += 1

        if cooldownSecs > 0 {
            steps.append(createStep(order: stepOrder, stepTypeKey: "cooldown", stepTypeId: 2, sport: sport,
                                    endCondition: "time", endValue: cooldownSecs, stroke: "any_stroke"))
        }
        return steps
    }

    static func buildStructuredSteps(_ steps: [[String: Any]], sport: String) -> [[String: Any]] {
        var workoutSteps: [[String: Any]] = []
        var stepOrder = 1

        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

        for step in steps {
            let stepTypeStr = GarminMappings.normalizeToken(step["type"] as? String, default: "interval")
            let stepType = GarminMappings.workoutStepTypes[stepTypeStr] ?? GarminMappings.workoutStepTypes["interval"]!

            if stepTypeStr == "repeat" {
                var repeatSteps: [[String: Any]] = []
                var childOrder = 1
                for child in step["repeat_steps"] as? [[String: Any]] ?? [] {
                    let childTypeStr = GarminMappings.normalizeToken(child["type"] as? String, default: "interval")
                    let childType = GarminMappings.workoutStepTypes[childTypeStr] ?? GarminMappings.workoutStepTypes["interval"]!
                    let childEnd = inferEndCondition(child, stepTypeStr: childTypeStr)
                    var childStep = createStep(
                        order: stepOrder + childOrder,
                        stepTypeKey: childType.key, stepTypeId: childType.id, sport: sport,
                        endCondition: childEnd,
                        endValue: num(child["distance_meters"]) ?? num(child["duration_seconds"]) ?? 60,
                        targetType: child["target_type"] as? String,
                        targetLow: num(child["target_low"]), targetHigh: num(child["target_high"]),
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

            let endCondition = inferEndCondition(step, stepTypeStr: stepTypeStr)
            workoutSteps.append(createStep(
                order: stepOrder,
                stepTypeKey: stepType.key, stepTypeId: stepType.id, sport: sport,
                endCondition: endCondition,
                endValue: num(step["distance_meters"]) ?? num(step["duration_seconds"]) ?? 60,
                targetType: step["target_type"] as? String,
                targetLow: num(step["target_low"]), targetHigh: num(step["target_high"]),
                stroke: step["stroke"] as? String
            ))
            stepOrder += 1
        }
        return workoutSteps
    }

    static func inferEndCondition(_ step: [String: Any], stepTypeStr: String) -> String {
        if let ec = step["end_condition"] as? String, !ec.isEmpty { return ec }
        if step["distance_meters"] != nil { return "distance" }
        if stepTypeStr == "rest" && step["duration_seconds"] != nil { return "fixed_rest" }
        if step["end_on_lap"] as? Bool == true { return "lap_button" }
        return "time"
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

        if swimSportKeys.contains(sport) {
            if stepTypeKey == "rest" {
                step["strokeType"] = GarminMappings.workoutStrokeNone
            } else {
                let strokeKey = stroke.map { GarminMappings.normalizeToken($0) }
                step["strokeType"] = GarminMappings.workoutStrokes[strokeKey ?? "free"] ?? GarminMappings.workoutStrokes["free"]!
            }
            step["equipmentType"] = ["equipmentTypeId": 0, "equipmentTypeKey": NSNull(), "displayOrder": 0]
        }

        return step
    }
}
