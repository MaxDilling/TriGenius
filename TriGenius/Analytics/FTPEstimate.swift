import Foundation

// MARK: - Cycling FTP estimated from VO2max

/// Recovers a cycling FTP for watches that never compute one (Fenix 6 Pro and
/// older, where the athlete is left entering a guess). Garmin's own auto-detected
/// FTP turns out to be a near-deterministic linear function of the cycling VO2max
/// the same watch already reports — so the capacity marker pins the threshold even
/// when no test ride exists. Derivation and validation: `ref/ftp_lab/FINDINGS.md`.
nonisolated enum FTPEstimate {

    /// Watts of threshold power per unit of *absolute* VO2max (ml/kg/min × kg).
    ///
    /// Scaling by mass rather than fitting a per-athlete intercept is what lets one
    /// constant serve every athlete: VO2max is reported per kilogram, so absolute
    /// power has to be scaled back up by body mass.
    ///
    /// Calibrated against Garmin's auto-detected FTP, which sits ~18 % above the
    /// same athlete's best 20-minute power. That gap is expected rather than an
    /// error — the reference rides contain no maximal effort, so `0.95 × best 20 min`
    /// understates the threshold there.
    static let wattsPerAbsoluteVO2 = 0.0584

    /// Cycling FTP (watts) implied by a cycling VO2max reading and body mass, or
    /// nil when either input is missing — an absent input yields no estimate.
    static func fromVO2max(_ vo2maxCycling: Double?, massKg: Double?) -> Double? {
        guard let vo2 = vo2maxCycling, vo2 > 0, let mass = massKg, mass > 0 else { return nil }
        return wattsPerAbsoluteVO2 * vo2 * mass
    }
}
