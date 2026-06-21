// Theme.swift
//
// Central design tokens for TriGenius. Every spacing value, corner radius and
// semantic color in the UI should resolve to one of these constants instead of
// a magic number, so the look stays consistent and is tunable in one place.
//
// See DESIGN.md for the rules these tokens encode.

import SwiftUI

enum Theme {

    /// Spacing scale. Use these for padding and stack spacing — favor the
    /// tighter end of the scale to keep layouts compact and data-dense.
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// Corner-radius scale. Three steps only — small controls, cards, hero
    /// containers. `.continuous` style is applied by the surface modifiers.
    enum Radius {
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
    }

    /// Semantic status colors. Reach for these names instead of raw `.orange`
    /// / `.green` / `.red` so intent is explicit and re-tintable later.
    enum Palette {
        static let warning = Color.orange
        static let success = Color.green
        static let info = Color.blue
        static let danger = Color.red
    }
}
