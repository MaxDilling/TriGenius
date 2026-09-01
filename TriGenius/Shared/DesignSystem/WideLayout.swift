// WideLayout.swift
//
// One definition of "there is room for columns" — iPad regular width and macOS —
// plus the layouts a section swaps to there. Sections keep the order the athlete
// configured; only their own content re-flows, so the dashboard fills the window
// instead of stretching a phone column across it.

import SwiftUI

struct WideLayout: DynamicProperty {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    var isWide: Bool { hSize == .regular }
    #else
    let isWide = true
    #endif

    /// Stat tiles beside their chart card (wide) or above it (compact) — the shared
    /// shape of the dashboard's Fitness & Form block and the Statistics PMC section.
    var outer: AnyLayout {
        isWide ? AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Spacing.m))
               : AnyLayout(VStackLayout(spacing: Theme.Spacing.m))
    }

    /// The tiles themselves: a column beside the chart, a row above it.
    var tiles: AnyLayout {
        isWide ? AnyLayout(VStackLayout(spacing: Theme.Spacing.m))
               : AnyLayout(HStackLayout(spacing: Theme.Spacing.m))
    }

    /// Width of that tile column; nil in the compact row, where the tiles share the
    /// full width between them.
    var tileColumnWidth: CGFloat? { isWide ? 200 : nil }

    /// Height for whichever side would otherwise leave a gap: both sides claim the
    /// row's height on wide, so the taller one sets it and the other fills.
    var rowHeight: CGFloat? { isWide ? .infinity : nil }
}
