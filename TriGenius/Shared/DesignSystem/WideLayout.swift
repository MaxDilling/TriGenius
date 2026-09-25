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

    /// Two blocks side by side (wide) or stacked (compact).
    var outer: AnyLayout {
        isWide ? AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Spacing.m))
               : AnyLayout(VStackLayout(spacing: Theme.Spacing.m))
    }
}
