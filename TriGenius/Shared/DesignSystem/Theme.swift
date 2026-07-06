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

        /// Discipline accent colors — single source for every sport-tinted UI element.
        static func sport(_ family: SportFamily) -> Color {
            switch family {
            case .swim: return .cyan
            case .bike: return .purple
            case .run: return .orange
            case .strength: return .gray
            case .other: return .green
            }
        }

        /// Training-zone palette, z1…z5 (low → high intensity).
        static let zones: [Color] = [info, success, .yellow, warning, danger]
    }
}

// MARK: - SportFamily presentation

extension SportFamily {
    var icon: String {
        switch self {
        case .swim: return "figure.pool.swim"
        case .bike: return "figure.outdoor.cycle"
        case .run: return "figure.run"
        case .strength: return "dumbbell"
        case .other: return "figure.mixed.cardio"
        }
    }

    var color: Color { Theme.Palette.sport(self) }
}
