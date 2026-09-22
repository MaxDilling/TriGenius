import Foundation

// MARK: - Cycling FTP from a reconstructed VO2max

/// Recovers a cycling FTP for watches that never compute one (fēnix 6 Pro and older,
/// where the athlete is left entering a guess).
///
/// Threshold power is the aerobic ceiling times the fraction of it the athlete holds at
/// threshold, converted from oxygen cost to watts at the efficiency a trained cyclist
/// rides at. Every term is published, so the constant is derived rather than fitted to
/// one watch's output — which is what lets it transfer to an athlete it was never
/// calibrated on. Its input is `VO2maxEstimate`, reconstructed from the athlete's own
/// submaximal riding.
///
/// Derivation and the rejected alternatives: `ref/threshold_lab/cycling/FINDINGS.md`.
nonisolated enum FTPEstimate {

    /// Gross efficiency of trained cyclists (Jobson review, 18–25 %).
    static let grossEfficiency = 0.22

    /// Fraction of VO2max held at threshold.
    static let fractionOfVO2max = 0.76

    /// Watts of metabolic energy per ml O₂/min — Péronnet & Massicotte, mixed substrate.
    static let wattsPerMlOxygenPerMinute = 20.9 / 60

    /// Watts of threshold power per unit of *absolute* VO2max (ml/kg/min × kg).
    ///
    /// Scaling by mass rather than fitting a per-athlete intercept is what lets one
    /// constant serve every athlete: VO2max is reported per kilogram, so absolute power
    /// has to be scaled back up by body mass.
    ///
    /// Unlike the running threshold this needs no per-athlete term. The fraction of
    /// heart-rate reserve the two reference athletes hold at cycling threshold differs by
    /// 1.2 % — worth 2 W, inside the ±2 W the FTP back-solve itself carries — against
    /// 8.4 % on the run, where it had to become an input.
    static let wattsPerAbsoluteVO2 = grossEfficiency * fractionOfVO2max * wattsPerMlOxygenPerMinute

    /// Cycling FTP (watts) implied by a cycling VO2max reading and body mass, or nil when
    /// either input is missing — an absent input yields no estimate.
    static func fromVO2max(_ vo2maxCycling: Double?, massKg: Double?) -> Double? {
        guard let vo2 = vo2maxCycling, vo2 > 0, let mass = massKg, mass > 0 else { return nil }
        return wattsPerAbsoluteVO2 * vo2 * mass
    }
}
