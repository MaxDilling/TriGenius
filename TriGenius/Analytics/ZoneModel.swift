import Foundation

// MARK: - Training zones: the model, the bucketing, and where the result lives
//
// The single definition of "a zone" for every metric and every source. A source's
// only job is to hand over its raw stream (`ZoneSamples`); the bounds come from the
// athlete's thresholds as of the activity's OWN date and the bucketing runs once, at
// ingest (`TSSScoring.score`) — the same place, and for the same reason, TL is scored
// there. So two sources report the same distribution for the same workout, and a new
// source gets time-in-zone without writing any zone code (see CLAUDE.md "Algorithms
// are source-independent").
//
// Every model runs on an axis that RISES with intensity, so `upperBounds` is ascending
// and a sample lands in the first zone it fits under. For pace that means SPEED (m/s),
// not pace (s/km) — which is also how TrainingPeaks states the running zones, as the
// percentages in parentheses next to Friel's pace percentages.

nonisolated enum ZoneMetric: String, CaseIterable, Codable, Sendable {
    case heartRate
    case power
    case pace

    /// Upper bounds of z1…z4 (z5 open-ended) in the metric's own unit, from the
    /// athlete's thresholds on the activity's date. Nil when this discipline has no
    /// zone model for the metric, or the measured threshold it needs is unknown — the
    /// zones then stay absent rather than resting on a guessed threshold.
    func upperBounds(snapshot: PerformanceSnapshot, family: SportFamily) -> [Double]? {
        switch self {
        case .heartRate:
            guard let lthr = snapshot.lactateThrHR, lthr > 0 else { return nil }
            return TSSConstants.hrZoneUpperFractionsOfLTHR.map { $0 * Double(lthr) }
        case .power:
            guard family == .bike, let ftp = snapshot.cyclingFTP, ftp > 0 else { return nil }
            return TSSConstants.powerZoneUpperFractionsOfFTP.map { $0 * Double(ftp) }
        case .pace:
            guard family == .run, let seconds = snapshot.lactateThrPaceSeconds, seconds > 0 else { return nil }
            let thresholdSpeed = 1000.0 / seconds
            return TSSConstants.paceZoneUpperFractionsOfThresholdSpeed.map { $0 * thresholdSpeed }
        }
    }

    /// How the athlete sees the metric — the bar's title.
    var displayName: String {
        switch self {
        case .heartRate: "Heart rate"
        case .power: "Power"
        case .pace: "Pace"
        }
    }

    /// Where this metric's results sit in a details dict: the per-sport section
    /// (nil = top level), the bucketed `{z1…z5: seconds}` key, and the z1–z4 upper
    /// bounds those seconds were bucketed against. The bounds are stored rather than
    /// re-derived at display time so the UI states what a zone meant for THIS
    /// workout — a threshold reading added later with an earlier date would shift a
    /// re-derivation while the stored seconds (and TL) stay as scored.
    /// `ZoneDistribution` reads back through this property, so the schema is stated
    /// exactly once.
    var detailsPath: (section: String?, seconds: String, bounds: String) {
        switch self {
        case .heartRate: (nil, "hr_zones_seconds", "hr_zones_bounds")
        case .power: ("cycling", "power_zones_seconds", "power_zones_bounds")
        case .pace: ("running", "pace_zones_seconds", "pace_zones_bounds")
        }
    }

    /// The zone model as fractions of threshold — the part that is true regardless
    /// of the athlete's current numbers, and the only honest answer when the bounds
    /// behind an aggregate differ.
    var thresholdFractions: [Double] {
        switch self {
        case .heartRate: TSSConstants.hrZoneUpperFractionsOfLTHR
        case .power: TSSConstants.powerZoneUpperFractionsOfFTP
        case .pace: TSSConstants.paceZoneUpperFractionsOfThresholdSpeed
        }
    }

    /// What the fractions are a fraction *of*.
    var thresholdName: String {
        switch self {
        case .heartRate: "LTHR"
        case .power: "FTP"
        case .pace: "threshold speed"
        }
    }

    /// `zone` is 0-based (0 = Z1). Zone 1 has no floor and zone 5 no ceiling, so each
    /// reads as open-ended. **Pace inverts**: its bounds rise in speed, so the faster
    /// zone shows the *lower* pace and Z1 is the SLOW end.
    func rangeText(zone: Int, bounds: [Double]) -> String? {
        guard bounds.count == 4, zone >= 0, zone < 5 else { return nil }
        let low = zone > 0 ? bounds[zone - 1] : nil       // in the metric's own unit
        let high = zone < 4 ? bounds[zone] : nil
        if self == .pace {
            // Speed → pace: the zone's speed floor is its pace ceiling.
            switch (low, high) {
            case let (nil, .some(h)): return "slower than \(Self.pace(h)) /km"
            case let (.some(l), nil): return "faster than \(Self.pace(l)) /km"
            case let (.some(l), .some(h)): return "\(Self.pace(l)) – \(Self.pace(h)) /km"
            default: return nil
            }
        }
        let unit = self == .heartRate ? "bpm" : "W"
        switch (low, high) {
        case let (nil, .some(h)): return "< \(Int(h.rounded())) \(unit)"
        case let (.some(l), nil): return "> \(Int(l.rounded())) \(unit)"
        case let (.some(l), .some(h)): return "\(Int(l.rounded())) – \(Int(h.rounded())) \(unit)"
        default: return nil
        }
    }

    /// The same range as percentages of threshold — always available, since it is the
    /// model rather than the athlete's current numbers.
    func fractionText(zone: Int) -> String? {
        let f = thresholdFractions
        guard f.count == 4, zone >= 0, zone < 5 else { return nil }
        func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))" }
        let text = switch zone {
        case 0: "< \(pct(f[0]))"
        case 4: "≥ \(pct(f[3]))"
        default: "\(pct(f[zone - 1]))–\(pct(f[zone]))"
        }
        return "\(text) % of \(thresholdName)"
    }

    /// m/s → "m:ss" per km; the unit is appended once by the caller so a range
    /// doesn't carry it twice.
    private static func pace(_ speedMps: Double) -> String {
        guard speedMps > 0 else { return "–" }
        let s = Int((1000.0 / speedMps).rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// One activity's — or one multisport leg's — raw zone input: the samples each metric
/// contributes, in that metric's own unit. Heart rate in bpm, power in watts, and pace
/// as the GRADE-ADJUSTED speed in m/s, the same equivalent-flat transform rTSS scores
/// on, so a hilly run's zones and its TL tell the same story. Shaping the raw stream
/// into this is the source's job; bucketing it is not.
typealias ZoneSamples = [ZoneMetric: [NormalizedStream.Sample]]

nonisolated enum ZoneBucketing {

    /// Bucket every metric that has both samples and a zone model on this date, and
    /// write the result into `details` at the metric's own path. A metric missing
    /// either input is left untouched — absence stays absence.
    static func apply(_ samples: ZoneSamples, to details: inout [String: Any], snapshot: PerformanceSnapshot) {
        let family = SportFamily(sportKey: details["sport"] as? String ?? "other")
        for metric in ZoneMetric.allCases {
            guard let stream = samples[metric], !stream.isEmpty,
                  let bounds = metric.upperBounds(snapshot: snapshot, family: family),
                  let zones = seconds(stream, upperBounds: bounds) else { continue }
            let dict = Dictionary(uniqueKeysWithValues: zones.enumerated().map {
                ("z\($0.offset + 1)", Int($0.element.rounded()))
            })
            let path = metric.detailsPath
            let rounded = bounds.map { ($0 * 100).rounded() / 100 }
            guard let section = path.section else {
                details[path.seconds] = dict
                details[path.bounds] = rounded
                continue
            }
            var contents = details[section] as? [String: Any] ?? [:]
            contents[path.seconds] = dict
            contents[path.bounds] = rounded
            details[section] = contents
        }
    }

    /// Seconds spent in each of z1…z5, or nil when nothing landed in any zone.
    /// `upperBounds` is the ascending z1–z4 ceiling list; z5 is everything above.
    static func seconds(_ samples: [NormalizedStream.Sample], upperBounds: [Double]) -> [Double]? {
        guard upperBounds.count == 4 else { return nil }
        var zones = [Double](repeating: 0, count: 5)
        for sample in samples where sample.seconds > 0 {
            zones[upperBounds.firstIndex { sample.value <= $0 } ?? 4] += sample.seconds
        }
        return zones.reduce(0, +) > 0 ? zones : nil
    }

    /// A point stream — `(offset seconds, value)`, the shape a 1 Hz or irregularly
    /// sampled source delivers — weighted by the gap to the next reading, so each
    /// sample carries the real time it stands for. The gap is capped so a recording
    /// pause is not counted as time in zone; the final sample stands for one second.
    static func durationSamples(_ points: [(offset: Double, value: Double)],
                                gapCapSeconds: Double = 30) -> [NormalizedStream.Sample] {
        let sorted = points.sorted { $0.offset < $1.offset }
        return sorted.indices.map { i in
            let seconds = i + 1 < sorted.count
                ? min(max(sorted[i + 1].offset - sorted[i].offset, 0), gapCapSeconds)
                : 1
            return (value: sorted[i].value, seconds: seconds)
        }
    }
}
