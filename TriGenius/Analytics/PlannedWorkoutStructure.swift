import SwiftUI

// MARK: - Planned workout structure (display model)
//
// Turns a planned workout's persisted compact steps
// (`WorkoutRecord.stepsJSON`) into a render-ready structure: a
// repeat-preserving step list with formatted extent/target strings, an estimated
// total distance, and abbreviated one-line summaries for compact rows. The step
// parsing and the distance/intensity math live in `PlannedTSS`; this layer only
// shapes and formats for the UI. Built from the same compact step shape both
// ingest paths produce (see `GarminService.compactSteps` and the coach's
// `add_workout`).

// MARK: Leaf + display step

/// One leaf (non-repeat) step of a planned workout, ready to display.
struct PlannedStepLeaf: Identifiable {
    let id = UUID()
    /// Step type key, lowercased ("warmup", "interval", "recovery", "cooldown", …).
    let typeKey: String
    /// True when the step ends on distance — `endValue` is meters, else seconds.
    let isDistance: Bool
    let endValue: Double
    /// "power" | "pace" | "speed" | "heart_rate" | "cadence", or nil for an untargeted step.
    let targetType: String?
    /// power: W · pace: sec (sec/km run/bike, sec/100 m swim) · speed: km/h · hr: bpm · cadence: rpm/spm.
    let targetLow: Double?
    let targetHigh: Double?

    var isRest: Bool { typeKey.contains("rest") || typeKey.contains("recover") }
}

/// A planned step in display order: a single leaf (`repeatCount == 1`) or a
/// repeated block, e.g. "3× (12 min @ 250–265 W / 4 min easy)".
struct PlannedDisplayStep: Identifiable {
    let id = UUID()
    let repeatCount: Int
    /// One leaf for a single step; the block body for a repeat.
    let steps: [PlannedStepLeaf]

    var isGroup: Bool { repeatCount > 1 }
    var leaf: PlannedStepLeaf? { repeatCount == 1 ? steps.first : nil }
    /// The first work (non-recovery) leaf of a block, used as its headline.
    var primaryWork: PlannedStepLeaf? { steps.first { !$0.isRest } ?? steps.first }
    var recovery: PlannedStepLeaf? { steps.first { $0.isRest } }
}

// MARK: Structure

struct PlannedWorkoutStructure {
    let family: SportFamily
    let steps: [PlannedDisplayStep]
    /// Estimated total distance in meters (pace-derived where possible). Surface
    /// only for distance disciplines (run / swim) where it reads naturally.
    let totalDistanceMeters: Double?
    /// How `totalDistanceMeters` was obtained (exact vs estimated). Nil alongside
    /// a nil distance.
    let distanceSource: DistanceSource?
    /// Estimated total duration in minutes, derived from the steps (distance steps
    /// converted via their pace target). Used as a duration fallback when the
    /// record carries no explicit `targetDurationMinutes`.
    let estimatedDurationMinutes: Double?

    /// Build from a record's persisted `stepsJSON`. Nil when there is no usable
    /// structure (empty steps, Garmin-Coach workouts, locally-created plans).
    static func make(stepsJSON: String, family: SportFamily) -> PlannedWorkoutStructure? {
        guard let data = stepsJSON.data(using: .utf8),
              let compact = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !compact.isEmpty else { return nil }
        let steps = parse(compact)
        guard !steps.isEmpty else { return nil }
        let distance = PlannedTSS.totalDistance(compactSteps: compact, family: family)
        return PlannedWorkoutStructure(
            family: family,
            steps: steps,
            totalDistanceMeters: distance?.meters,
            distanceSource: distance?.source,
            estimatedDurationMinutes: PlannedTSS.totalDurationSeconds(compactSteps: compact, family: family).map { $0 / 60 }
        )
    }

    // MARK: Parsing

    private static func parse(_ compact: [[String: Any]]) -> [PlannedDisplayStep] {
        var out: [PlannedDisplayStep] = []
        for step in compact {
            if let children = step["repeat_steps"] as? [[String: Any]] {
                let count = max(1, Coerce.double(step["repeat_count"]).map { Int($0) } ?? 1)
                let leaves = children.compactMap { leaf(from: $0) }
                guard !leaves.isEmpty else { continue }
                if count > 1 {
                    out.append(PlannedDisplayStep(repeatCount: count, steps: leaves))
                } else {
                    out.append(contentsOf: leaves.map { PlannedDisplayStep(repeatCount: 1, steps: [$0]) })
                }
            } else if let l = leaf(from: step) {
                out.append(PlannedDisplayStep(repeatCount: 1, steps: [l]))
            }
        }
        return out
    }

    private static func leaf(from step: [String: Any]) -> PlannedStepLeaf? {
        guard step["repeat_steps"] == nil else { return nil }   // nested repeats are rare; skip
        let typeKey = (step["type"] as? String)?.lowercased() ?? "interval"
        let isDistance: Bool
        let endValue: Double
        if let m = Coerce.double(step["distance_meters"]), m > 0 {
            isDistance = true; endValue = m
        } else if let s = Coerce.double(step["duration_seconds"]), s > 0 {
            isDistance = false; endValue = s
        } else {
            return nil
        }
        var target = step["target_type"] as? String
        if target == "no_target" { target = nil }
        return PlannedStepLeaf(
            typeKey: typeKey, isDistance: isDistance, endValue: endValue,
            targetType: target,
            targetLow: Coerce.double(step["target_low"]),
            targetHigh: Coerce.double(step["target_high"])
        )
    }

    // MARK: Target formatting (needs family for pace units)

    /// Full target string for a step, e.g. "250–265 W", "4:30–4:50 /km",
    /// "145–155 bpm", "30–32 km/h", "85–90 rpm".
    func targetText(_ leaf: PlannedStepLeaf) -> String? {
        guard let type = leaf.targetType else { return nil }
        switch type {
        case "power":      return PlannedWorkoutFormat.range(leaf.targetLow, leaf.targetHigh, unit: "W")
        case "heart_rate": return PlannedWorkoutFormat.range(leaf.targetLow, leaf.targetHigh, unit: "bpm")
        case "pace":       return PlannedWorkoutFormat.paceRange(leaf.targetLow, leaf.targetHigh, swim: family == .swim)
        case "speed":      return PlannedWorkoutFormat.speedRange(leaf.targetLow, leaf.targetHigh)
        case "cadence":    return PlannedWorkoutFormat.range(leaf.targetLow, leaf.targetHigh, unit: cadenceUnit)
        default:           return nil
        }
    }

    /// Cadence unit per discipline: cycling counts crank revolutions (rpm),
    /// running and swimming count steps / strokes per minute (spm).
    private var cadenceUnit: String { family == .bike ? "rpm" : "spm" }

    // MARK: Summaries

    /// Abbreviated one-line structure, e.g. "WU 10' · 3×12' @ 250–265W · CD 10'".
    var structuredSummary: String {
        steps.map(summaryPart).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A short hint for compact rows describing the main set, e.g. "3×12'" or
    /// "5k + 4×20\"". Only shown for structured sessions with a repeat block (a
    /// plain steady session is already covered by its duration/distance + TSS);
    /// lists every work segment, skipping warm-up / cool-down / recovery.
    var compactHint: String? {
        guard steps.contains(where: { $0.isGroup }) else { return nil }
        let tokens = steps.compactMap(workToken)
        return tokens.isEmpty ? nil : tokens.joined(separator: " + ")
    }

    /// Compact token for a single step's work portion: "N×<abbrev>" for a repeat
    /// block, the bare abbrev for a standalone work leaf, nil for warm-up /
    /// cool-down / recovery / rest (kept out of the compact hint).
    private func workToken(_ step: PlannedDisplayStep) -> String? {
        if step.isGroup {
            guard let work = step.primaryWork else { return nil }
            return "\(step.repeatCount)×\(PlannedWorkoutFormat.abbrev(work))"
        }
        guard let leaf = step.leaf, !leaf.isRest,
              !leaf.typeKey.contains("warm"), !leaf.typeKey.contains("cool"),
              !leaf.typeKey.contains("recover") else { return nil }
        return PlannedWorkoutFormat.abbrev(leaf)
    }

    private func summaryPart(_ step: PlannedDisplayStep) -> String {
        if step.isGroup {
            guard let work = step.primaryWork else { return "" }
            var s = "\(step.repeatCount)×\(PlannedWorkoutFormat.abbrev(work))"
            if let t = targetText(work) { s += " @ \(t.replacingOccurrences(of: " ", with: ""))" }
            if let rec = step.recovery { s += " / \(PlannedWorkoutFormat.abbrev(rec))" }
            return s
        }
        guard let leaf = step.leaf else { return "" }
        if leaf.typeKey.contains("warm") { return "WU \(PlannedWorkoutFormat.abbrev(leaf))" }
        if leaf.typeKey.contains("cool") { return "CD \(PlannedWorkoutFormat.abbrev(leaf))" }
        var s = PlannedWorkoutFormat.abbrev(leaf)
        if let t = targetText(leaf) { s += " @ \(t.replacingOccurrences(of: " ", with: ""))" }
        return s
    }
}

// MARK: - Intensity category

/// The character of a planned session, derived from its intensity factor (IF).
/// IF comes from the standard `TSS = IF² × hours × 100`, so it can be computed
/// from the already-stored planned TSS + duration — no thresholds needed at the
/// view layer.
enum IntensityCategory: String, CaseIterable {
    case recovery, endurance, tempo, threshold, vo2max

    var label: String {
        switch self {
        case .recovery:  return "Recovery"
        case .endurance: return "Endurance"
        case .tempo:     return "Tempo"
        case .threshold: return "Threshold"
        case .vo2max:    return "VO₂max"
        }
    }

    var color: Color {
        switch self {
        case .recovery:  return Theme.Palette.success
        case .endurance: return Theme.Palette.info
        case .tempo:     return .yellow
        case .threshold: return Theme.Palette.warning
        case .vo2max:    return Theme.Palette.danger
        }
    }

    static func from(intensityFactor factor: Double) -> IntensityCategory {
        switch factor {
        case ..<0.55: return .recovery
        case ..<0.75: return .endurance
        case ..<0.85: return .tempo
        case ..<0.95: return .threshold
        default:      return .vo2max
        }
    }

    /// Derive from a planned TSS over a duration. Nil when either is non-positive.
    static func from(tss: Double, durationMinutes: Double) -> IntensityCategory? {
        guard tss > 0, durationMinutes > 0 else { return nil }
        let hours = durationMinutes / 60
        return from(intensityFactor: (tss / (hours * 100)).squareRoot())
    }
}

// MARK: - Formatting helpers

enum PlannedWorkoutFormat {

    /// Full extent text: "12 min", "1:30", "45 s", "400 m", "5 km".
    static func extent(_ leaf: PlannedStepLeaf) -> String {
        leaf.isDistance ? distance(leaf.endValue) : duration(leaf.endValue)
    }

    /// Abbreviated extent for summaries: "12'", "30\"", "1:30", "400m", "5k".
    static func abbrev(_ leaf: PlannedStepLeaf) -> String {
        if leaf.isDistance {
            let m = leaf.endValue
            if m >= 1000 {
                let km = m / 1000
                return km.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(km))k" : String(format: "%.1fk", km)
            }
            return "\(Int(m.rounded()))m"
        }
        let s = Int(leaf.endValue.rounded())
        if s % 60 == 0 { return "\(s / 60)'" }
        if s < 60 { return "\(s)\"" }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s % 60 == 0 { return "\(s / 60) min" }
        if s < 60 { return "\(s) s" }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func distance(_ meters: Double) -> String {
        if meters >= 1000 {
            let km = meters / 1000
            return km.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f km", km) : String(format: "%.1f km", km)
        }
        return "\(Int(meters.rounded())) m"
    }

    /// A numeric target range, e.g. "250–265 W" (or "250 W" when low == high).
    static func range(_ low: Double?, _ high: Double?, unit: String) -> String? {
        let lo = low.map { Int($0.rounded()) }
        let hi = high.map { Int($0.rounded()) }
        switch (lo, hi) {
        case let (l?, h?) where l != h: return "\(min(l, h))–\(max(l, h)) \(unit)"
        case let (l?, _):               return "\(l) \(unit)"
        case let (_, h?):               return "\(h) \(unit)"
        default:                        return nil
        }
    }

    /// A pace target range in "m:ss" with the right per-distance unit. Pace is
    /// stored as seconds, smaller = faster, so the range reads fast–slow.
    static func paceRange(_ low: Double?, _ high: Double?, swim: Bool) -> String? {
        let unit = swim ? "/100m" : "/km"
        let lo = low.flatMap { $0 > 0 ? $0 : nil }
        let hi = high.flatMap { $0 > 0 ? $0 : nil }
        switch (lo, hi) {
        case let (l?, h?) where abs(l - h) >= 1:
            return "\(mmss(min(l, h)))–\(mmss(max(l, h))) \(unit)"
        case let (l?, _): return "\(mmss(l)) \(unit)"
        case let (_, h?): return "\(mmss(h)) \(unit)"
        default:          return nil
        }
    }

    private static func mmss(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// A speed target range in km/h, e.g. "30–32 km/h" (or "30 km/h" when low == high).
    /// One decimal only when a value isn't whole, to stay compact.
    static func speedRange(_ low: Double?, _ high: Double?) -> String? {
        let lo = low.flatMap { $0 > 0 ? $0 : nil }
        let hi = high.flatMap { $0 > 0 ? $0 : nil }
        switch (lo, hi) {
        case let (l?, h?) where abs(l - h) >= 0.1:
            return "\(kmh(min(l, h)))–\(kmh(max(l, h))) km/h"
        case let (l?, _): return "\(kmh(l)) km/h"
        case let (_, h?): return "\(kmh(h)) km/h"
        default:          return nil
        }
    }

    private static func kmh(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(v)) : String(format: "%.1f", v)
    }
}

// MARK: - WorkoutRecord display bridge
//
// The single source of truth for a planned workout's derived display values,
// shared by every compact row (Agenda, Calendar, Week) and the detail view so
// they stay consistent.

/// A planned workout's distance plus how it was derived (see `DistanceSource`).
struct PlannedDistance {
    var meters: Double
    var source: DistanceSource
}

extension WorkoutRecord {
    var family: SportFamily { SportFamily(sportKey: sport) }

    /// Parsed structured steps, when the workout carries any.
    var structure: PlannedWorkoutStructure? {
        PlannedWorkoutStructure.make(stepsJSON: stepsJSON, family: family)
    }

    /// Best planned duration in minutes. Prefers the structure-derived estimate,
    /// which converts distance-prescribed steps (e.g. a "4 km @ 5:40/km" interval)
    /// into time — something the stored `targetDurationMinutes` can't capture, so
    /// for mixed time+distance sessions it would otherwise undercount. Falls back
    /// to the explicit target when there is no structure.
    var plannedDurationMinutes: Double {
        if let estimated = structure?.estimatedDurationMinutes, estimated > 0 { return estimated }
        return targetDurationMinutes
    }

    /// True when the planned TSS is estimated from duration (no explicit target).
    var isEstimatedTSS: Bool { targetTSS == nil }

    /// Planned TSS — the explicit target, else estimated from duration.
    var resolvedTargetTSS: Double {
        targetTSS ?? WeeklyTargets.estimatedTSS(family: family, minutes: targetDurationMinutes)
    }

    /// Planned distance for the workout, with how it was derived: the structured
    /// steps when present (exact for distance-prescribed steps, pace-derived
    /// otherwise), else duration × the discipline's default speed. Nil for
    /// sessions with no meaningful distance (strength, or no steps and no
    /// duration) — `estimatedDistanceKm` returns 0 for those.
    var plannedDistance: PlannedDistance? {
        if let s = structure, let m = s.totalDistanceMeters, m > 0, let src = s.distanceSource {
            return PlannedDistance(meters: m, source: src)
        }
        let km = WeeklyTargets.estimatedDistanceKm(family: family, minutes: targetDurationMinutes)
        return km > 0 ? PlannedDistance(meters: km * 1000, source: .estimatedFromDuration) : nil
    }

    /// Session character, derived from the planned TSS + duration.
    var intensity: IntensityCategory? {
        IntensityCategory.from(tss: resolvedTargetTSS, durationMinutes: targetDurationMinutes)
    }

    /// The shared "[segment •] duration • TSS [• interval hint]" line every
    /// compact planned-workout row shows. `uppercased` matches the Agenda styling;
    /// `tssSuffix` is "TSS" or "TSS target" depending on the surface.
    func plannedSummaryLine(segment: TimeOfDaySegment? = nil,
                            uppercased: Bool = false,
                            tssSuffix: String = "TSS") -> String {
        var parts: [String] = []
        if let segment { parts.append(segment.label) }
        if targetDurationMinutes > 0 {
            let d = durationHM(targetDurationMinutes)
            parts.append(uppercased ? d.uppercased() : d)
        }
        let tss = resolvedTargetTSS
        if tss > 0 {
            parts.append("\(isEstimatedTSS ? "~" : "")\(Int(tss.rounded())) \(tssSuffix)")
        }
        if let hint = structure?.compactHint { parts.append(hint) }
        return parts.isEmpty ? "Target not set" : parts.joined(separator: "  •  ")
    }
}

// MARK: - Step display affordances

extension PlannedStepLeaf {
    /// Human label for the step type.
    var typeLabel: String {
        let k = typeKey
        if k.contains("warm") { return "Warm-up" }
        if k.contains("cool") { return "Cool-down" }
        if k.contains("recover") { return "Recovery" }
        if k.contains("rest") { return "Rest" }
        if k == "interval" || k == "active" || k == "main" || k == "work" { return "Interval" }
        return k.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// SF Symbol for the step type.
    var icon: String {
        let k = typeKey
        if k.contains("warm") { return "sunrise.fill" }
        if k.contains("cool") { return "sunset.fill" }
        if k.contains("recover") { return "wind" }
        if k.contains("rest") { return "pause.circle.fill" }
        return "bolt.fill"
    }
}
