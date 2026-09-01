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

    /// The standard content card on the dashboard and statistics screens: padded,
    /// full width, on real Liquid Glass. The screen groups them under one
    /// `GlassEffectContainer` so the panes blend as a single glass system.
    func glassCard(padding: CGFloat = Theme.Spacing.l) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: Theme.Radius.l)
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

// MARK: - Section heading

/// Page-level section heading: freestanding above the section's content and a
/// clear size step above anything inside a card, so it visibly scopes the block
/// below it. Cards carry no title of their own — one that must name itself uses a
/// small secondary caption row instead.
///
/// The optional accessory is for *actions* (an add button), never navigation:
/// with no chevrons anywhere, every card is a door and the heading stays a label.
struct SectionHeading<Accessory: View>: View {
    private let title: String
    private let accessory: Accessory

    init(_ title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack {
            Text(title).font(.title2.bold())
            Spacer()
            accessory
        }
    }
}

extension SectionHeading where Accessory == EmptyView {
    init(_ title: String) { self.init(title) { EmptyView() } }
}
