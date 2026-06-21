// Surfaces.swift
//
// The two surface layers of TriGenius, plus the "Silent AI" signal.
//
//  - cardSurface:  the CONTENT layer. Opaque, grouped background for
//                  data-dense content (metrics, lists, detail rows). This is
//                  the default — most of the UI lives here.
//  - glassSurface: the CONTROL / NAVIGATION layer. Apple's real Liquid Glass
//                  (`glassEffect`, iOS/macOS 26+), reserved for floating and
//                  grouping chrome — toolbars, the coach chat bubble, a day
//                  column container. Never stack glass on glass or put dense
//                  data straight on it.
//  - coachAccent:  signals that the CoachBrain created/modified an element,
//                  via a subtle static tinted hairline — no badge, no pulse.
//
// See DESIGN.md for the rules these modifiers encode.

import SwiftUI

extension View {

    /// Content-layer card: opaque grouped background with compact padding.
    func cardSurface(
        cornerRadius: CGFloat = Theme.Radius.m,
        padding: CGFloat = Theme.Spacing.m
    ) -> some View {
        self
            .padding(padding)
            .background(
                Color.appSecondaryBackground,
                in: .rect(cornerRadius: cornerRadius, style: .continuous)
            )
    }

    /// Control/navigation-layer Liquid Glass. Pass a `tint` to color the glass
    /// (e.g. a discipline color) instead of painting a solid block behind it.
    func glassSurface(
        cornerRadius: CGFloat = Theme.Radius.m,
        tint: Color? = nil
    ) -> some View {
        let glass: Glass = tint.map { .regular.tint($0) } ?? .regular
        return self.glassEffect(glass, in: .rect(cornerRadius: cornerRadius, style: .continuous))
    }

    /// "Silent AI" signal: a static tinted hairline border around a surface to
    /// mark coach-generated/modified content. Deliberately not a badge or a
    /// pulsing glow.
    func coachAccent(
        _ color: Color = .accentColor,
        cornerRadius: CGFloat = Theme.Radius.m
    ) -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(color.opacity(0.4), lineWidth: 1)
        )
    }
}
