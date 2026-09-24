// Color+App.swift
//
// Cross-platform system colors.
//
// The `*SystemBackground` / `*Label` colors only exist on UIKit (iOS).
// These helpers map them to the AppKit equivalents on macOS so the same
// SwiftUI code compiles for both platforms. These are the opaque "content
// layer" surfaces — Liquid Glass (see Surfaces.swift) is reserved for the
// floating control / navigation layer.

import SwiftUI

extension Color {
    static var appBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    static var appSecondaryBackground: Color {
        #if os(macOS)
        Color(nsColor: .underPageBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    static var appTertiaryBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .tertiarySystemBackground)
        #endif
    }

    static var appTertiaryLabel: Color {
        #if os(macOS)
        Color(nsColor: .tertiaryLabelColor)
        #else
        Color(uiColor: .tertiaryLabel)
        #endif
    }

    /// Build a color from a `#RRGGBB` (or `RRGGBB`) hex string. Falls back to a
    /// neutral gray for malformed input.
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            self = .gray
            return
        }
        self = Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Adaptive color from the two sRGB hex values of one token (0xRRGGBB). For design
    /// tokens whose light and dark variants are chosen for contrast rather than derived
    /// from each other — `Theme.Palette.Tissue` is the caller.
    static func appAdaptive(light: UInt32, dark: UInt32,
                            lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        func components(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
        }
        let (lr, lg, lb) = components(light), (dr, dg, db) = components(dark)
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: dr, green: dg, blue: db, alpha: darkAlpha)
                : NSColor(srgbRed: lr, green: lg, blue: lb, alpha: lightAlpha)
        })
        #else
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: dr, green: dg, blue: db, alpha: darkAlpha)
                : UIColor(red: lr, green: lg, blue: lb, alpha: lightAlpha)
        })
        #endif
    }
}
