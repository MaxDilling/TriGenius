// DateFormatting.swift
//
// Shared, cached date formatters. Calendar dates throughout the app use a
// stable `yyyy-MM-dd` POSIX representation (memory JSON, Garmin payloads,
// metric keys, cache buckets) — defining the formatter once avoids both the
// duplication and the per-call allocation of recreating one inline.

import Foundation

extension DateFormatter {
    /// `yyyy-MM-dd`, POSIX locale — the canonical calendar-date format.
    nonisolated static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
