import Foundation

// MARK: - TSS (Training Stress Score)
//
// Single source of truth for the TSS of an activity. Today TSS is taken
// verbatim from Garmin's `activityTrainingLoad` (stored on `ActivityRecord.tss`
// during sync). Later we will compute TSS ourselves (from duration + intensity:
// rTSS / sTSS / hrTSS), at which point ONLY this file changes — every caller
// reads TSS through here and stays unaffected.

enum TSS {
    /// The TSS of a stored activity, or nil when the source provided no value
    /// (e.g. HealthKit). Callers that need a number for aggregation should treat
    /// nil as 0; callers that display it should show "—".
    @MainActor
    static func value(for record: ActivityRecord) -> Double? {
        record.tss
    }
}
