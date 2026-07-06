import Foundation

// MARK: - ATP per-sport split (approach A)
//
// The ONLY sport-aware piece of the ATP. The engine produces one sport-agnostic
// weekly TSS (kept that way so it stays TP-calibratable); this layer divides it
// across disciplines. Pure — the athlete's ratio + floors come from the profile
// (`WeeklyStructure`) at the call site (wired with the WeeklyTarget integration).

enum ATPSportSplit {

    /// Split a week's TSS across disciplines: allocate by the athlete's `ratio`,
    /// raise any discipline below its `floor`, and rescale the rest so the week
    /// total is preserved. `ratio` weights needn't sum to 1; `floors` is a per-sport
    /// minimum weekly TSS (e.g. a swim floor for a bike-heavy athlete who'd
    /// otherwise neglect it). Empty when there's nothing to split.
    static func split(
        weeklyTSS total: Double,
        ratio: [SportFamily: Double],
        floors: [SportFamily: Double] = [:]
    ) -> [SportFamily: Double] {
        let weightTotal = ratio.values.reduce(0, +)
        guard total > 0, weightTotal > 0 else { return [:] }

        var alloc: [SportFamily: Double] = [:]
        for (sport, w) in ratio { alloc[sport] = total * w / weightTotal }

        // Raise sports under their floor (capped at the week total); these are fixed.
        var fixed: Set<SportFamily> = []
        for (sport, floor) in floors {
            let f = min(floor, total)
            if (alloc[sport] ?? 0) < f { alloc[sport] = f; fixed.insert(sport) }
        }

        // Rescale the non-fixed sports so the disciplines still sum to `total`.
        let fixedSum = fixed.reduce(0.0) { $0 + (alloc[$1] ?? 0) }
        let freeSum = alloc.filter { !fixed.contains($0.key) }.values.reduce(0, +)
        let freeBudget = max(0, total - fixedSum)
        if freeSum > 0 {
            for (sport, v) in alloc where !fixed.contains(sport) {
                alloc[sport] = v * freeBudget / freeSum
            }
        }
        return alloc.mapValues { $0.rounded() }
    }
}
