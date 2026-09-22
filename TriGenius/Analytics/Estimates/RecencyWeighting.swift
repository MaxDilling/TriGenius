import Foundation

// MARK: - Recency weighting shared by the threshold estimators

/// Age weighting and the weighted quantile the threshold estimators reduce their
/// evidence with. Both `LTHREstimate` and `VO2maxEstimate` select the best efforts an
/// athlete happens to have produced, so both need the same two operations, and a second
/// copy of either would be free to drift.
nonisolated enum RecencyWeighting {

    /// Cauchy kernel `1 / (1 + (age/τ)²)`.
    ///
    /// Chosen over an exponential for its heavy tail. A threshold moves slowly, and an
    /// exponential decaying fast enough to track a real change discards a season of
    /// evidence to do it — the tail is what makes a thin pool usable at all. That same
    /// tail is why this must not be used for a quantity whose level moves faster than
    /// its evidence accumulates.
    static func weight(ageDays: Double, tauDays: Double) -> Double {
        1 / (1 + (ageDays / tauDays) * (ageDays / tauDays))
    }

    /// Quantile `q` of `values` under `weights`, linearly interpolated.
    ///
    /// Returns nil only for an empty sample; a single value is its own quantile.
    static func quantile(_ values: [Double], weights: [Double], q: Double) -> Double? {
        guard !values.isEmpty, values.count == weights.count else { return nil }
        let sorted = zip(values, weights).sorted { $0.0 < $1.0 }
        let total = sorted.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }

        // Position each value at the midpoint of the weight it carries, so a sample of
        // equal weights reproduces the ordinary linear-interpolation quantile.
        var cumulative = 0.0
        var positions: [Double] = []
        positions.reserveCapacity(sorted.count)
        for (_, w) in sorted {
            positions.append((cumulative + 0.5 * w) / total)
            cumulative += w
        }
        if q <= positions[0] { return sorted[0].0 }
        if q >= positions[positions.count - 1] { return sorted[sorted.count - 1].0 }
        for i in 1 ..< positions.count where q <= positions[i] {
            let span = positions[i] - positions[i - 1]
            let t = span > 0 ? (q - positions[i - 1]) / span : 0
            return sorted[i - 1].0 + (sorted[i].0 - sorted[i - 1].0) * t
        }
        return sorted[sorted.count - 1].0
    }
}

// MARK: - How much an estimate can be trusted

/// What an estimate rests on. Carried alongside every threshold estimate rather than
/// left to the caller to derive: these estimators select the best evidence available,
/// which makes added easy volume inert but also means the number freezes when no hard
/// effort arrives — and a bare value cannot say whether it describes this week or April.
nonisolated enum EstimateConfidence: String, Sendable, Codable {
    /// Enough qualifying efforts, the newest of them recent.
    case anchored
    /// Below the effort count where the aggregate stops being a robust one; the value
    /// stands, but a single session moves it.
    case thin
    /// The evidence it rests on is older than a training block, so it describes the past.
    case stale
    /// No qualifying effort has ever been observed, so the value rests on a population
    /// constant rather than on anything the athlete did.
    case rough
}
