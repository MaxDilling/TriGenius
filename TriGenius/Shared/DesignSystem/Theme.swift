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

    /// Floating control-layer metrics. Every tab's header pill shares this height
    /// so the chrome lines up across Plan, Coach and Calendar — it matches the
    /// system toolbar control the tabs used before they grew their own headers.
    enum Chrome {
        static let pillHeight: CGFloat = 44
    }

    /// Semantic status colors. Reach for these names instead of raw `.orange`
    /// / `.green` / `.red` so intent is explicit and re-tintable later.
    enum Palette {
        static let warning = Color.orange
        static let success = Color.green
        static let info = Color.blue
        static let danger = Color.red

        /// PMC series identity — CTL / ATL / TSB wear these wherever they appear:
        /// tiles, chart lines, legend, tooltip, the Form axis. The Form *bars* are
        /// the exception, signalling fresh vs. fatigued with `success` / `warning`.
        static let fitness = Color.blue
        static let fatigue = Color.pink
        static let form = Color.orange

        /// Planned / reference series, drawn behind the actual one it is compared to.
        static let plan = Color.gray

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

        /// Tissue Load — the structural load axis. The load ramp runs from the clear grey
        /// to one deep red, under-target is the fitness blue, conflict the warning.
        /// Colour is never the only channel — muscle draws as a bar, tendon as a
        /// diamond, a conflict as a triangle — so every state survives greyscale.
        enum Tissue {
            /// Empty track: clear for hard work. The absence of load, never green —
            /// loaded tissue in a build week is the plan working, not a failure.
            static let clear = Color.appAdaptive(light: 0xE5E5EA, dark: 0x48484A)
            /// Outline of a clear tendon diamond, and the grid hairlines.
            static let clearStroke = Color.appAdaptive(light: 0xAEAEB2, dark: 0x7C7C80)

            /// Heavy load. Every level below it is the clear grey blended toward it in
            /// quarter steps — one deep red, never a pink ramp. Brighter in dark mode, so
            /// more load also means more light against the dark card, not just more hue.
            static let heavy = Color.appAdaptive(light: 0x900000, dark: 0xE0453A)

            static func load(_ level: LoadLevel) -> Color {
                level == .fresh ? clear : clear.mix(with: heavy, by: Double(level.rawValue) / 4)
            }

            /// 6-week view, diverging around the target band: under-target bars grow down
            /// in these, over-target bars grow up in the Moderate / Loaded load colour.
            static let underStrong = Theme.Palette.info
            static let under = Color.appAdaptive(light: 0x8EC0FF, dark: 0x4A80C4)
            static let targetBand = Color.appAdaptive(light: 0xD1D1D6, dark: 0x545458)

            /// A conflict is carried by its triangle and outline. This never tints text —
            /// warning on white is 2.2:1.
            static let conflict = Theme.Palette.warning
            /// Container tint behind a conflict row. The container may be translucent;
            /// the numbers on it stay opaque.
            static let conflictFill = Color.appAdaptive(light: 0xFF9500, dark: 0xFF9F0A,
                                                        lightAlpha: 0.14, darkAlpha: 0.18)

            /// Calendar all-day chip for strength: darker than `sport(.strength)` so the
            /// white title clears 4.5:1. Dots and the timed block keep the sport grey.
            static let strengthChip = Color(hex: "6E6E73")
        }
    }
}

/// The app-wide duration format: "1:05h", "0:45h". Always hours-and-minutes —
/// a bare "50m" reads as 50 metres next to a swim's distances.
func durationHM(_ minutes: Double) -> String {
    let total = Int(minutes.rounded())
    return String(format: "%d:%02dh", total / 60, total % 60)
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

    /// Distance for display. Swims read in metres, the unit a session is
    /// measured in, as does any sub-kilometre distance ("600 m"); `decimals`
    /// applies to the kilometre form only.
    func distanceLabel(_ km: Double, decimals: Int = 2) -> String {
        guard self != .swim, km >= 1 else { return "\(Int((km * 1000).rounded())) m" }
        return String(format: "%.\(decimals)f km", km)
    }
}
