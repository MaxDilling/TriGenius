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
}
