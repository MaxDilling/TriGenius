//  PhasePresentation.swift
//  Presentation-only helpers for training-plan phases (color, icon). Kept out of
//  CoachMemory so the model stays UI-agnostic.

import SwiftUI

extension PhaseName {
    /// Display name for the phase as shown in the UI (English).
    var displayName: String { rawValue }

    /// Accent color for the phase, roughly following a base→peak→taper warm-up.
    var color: Color {
        switch self {
        case .prep:       return .teal
        case .base:       return .green
        case .build:      return .orange
        case .peak:       return .red
        case .taper:      return .purple
        case .race:       return .pink
        case .recovery:   return .blue
        case .transition: return .gray
        }
    }

    var icon: String {
        switch self {
        case .prep:       return "figure.cooldown"
        case .base:       return "chart.line.uptrend.xyaxis"
        case .build:      return "flame.fill"
        case .peak:       return "mountain.2.fill"
        case .taper:      return "arrow.down.right.circle"
        case .race:       return "flag.checkered"
        case .recovery:   return "bed.double.fill"
        case .transition: return "arrow.triangle.2.circlepath"
        }
    }
}
