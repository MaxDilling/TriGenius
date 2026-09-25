// Surfaces.swift
//
// The two surface layers of TriGenius, plus the "Silent AI" signal.
//
//  - cardSurface:  the CONTENT layer. Opaque, grouped background for every
//                  card, tile and detail row — all of the app's data.
//  - glassSurface: the CONTROL / NAVIGATION layer. Apple's real Liquid Glass,
//                  reserved for floating chrome — header pills, the coach chat
//                  bubble, a day column container. Never put data on it.
//  - coachAccent:  signals that the CoachBrain created/modified an element,
//                  via a subtle static tinted hairline — no badge, no pulse.
//
// See docs/design.md for the rules these modifiers encode.

import SwiftUI

extension View {

    /// Content-layer card: opaque grouped background. Every card insets its content
    /// by the same `Theme.Spacing.l`.
    func cardSurface(
        cornerRadius: CGFloat = Theme.Radius.l,
        padding: CGFloat = Theme.Spacing.l
    ) -> some View {
        self
            .padding(padding)
            .background(
                Color.appSecondaryBackground,
                in: .rect(cornerRadius: cornerRadius, style: .continuous)
            )
    }

    /// A full-width content card — the standard block under a `SectionHeading`.
    func contentCard(padding: CGFloat = Theme.Spacing.l) -> some View {
        frame(maxWidth: .infinity, alignment: .leading).cardSurface(padding: padding)
    }

    /// One control in a screen header: a glass capsule at the shared chrome height.
    /// `minWidth` matches the height so a single narrow glyph renders as a circle
    /// rather than a tall oval; wider content (a label, two icons) grows past it.
    func headerPill() -> some View {
        self.padding(.horizontal, Theme.Spacing.m)
            .frame(height: Theme.Chrome.pillHeight)
            .frame(minWidth: Theme.Chrome.pillHeight)
            .glassSurface(cornerRadius: Theme.Chrome.pillHeight / 2)
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
        cornerRadius: CGFloat = Theme.Radius.l
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
/// below it. The optional accessory is for *actions* (an add button, a picker),
/// never navigation — a card that leads somewhere carries its own `Chevron`.
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

/// The disclosure mark on anything that leads somewhere — tiles, rows, banners.
struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
}

// MARK: - Screen header

/// A tab's top chrome: the screen title, big and leading, on the *same row* as its
/// controls. Deliberately not `navigationBarTitleDisplayMode(.large)` — that puts
/// the title on its own row below the controls, which reads as two unrelated
/// bands. Tabs using this hide the navigation bar (`CalendarNavBar` builds its own
/// variant on the same metrics, because its leading slot changes with the mode).
struct ScreenHeader<Controls: View>: View {
    private let title: String
    private let controls: Controls

    init(_ title: String, @ViewBuilder controls: () -> Controls) {
        self.title = title
        self.controls = controls()
    }

    var body: some View {
        GlassEffectContainer(spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                // Shrinks rather than wraps: the dashboard's title is the athlete's
                // own name, so its width isn't ours to bound.
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: Theme.Spacing.s)
                controls
            }
        }
        .frame(minHeight: Theme.Chrome.pillHeight)
    }
}

// MARK: - Card title

extension View {
    /// A card's title above its content — one font and one gap on every card, Apple
    /// Health's weight.
    func cardTitle(_ title: String, systemImage: String? = nil) -> some View {
        cardTitle(title, systemImage: systemImage) { EmptyView() }
    }

    /// The same, with an `accessory` (a picker, an Edit button) trailing the title.
    func cardTitle(_ title: String, systemImage: String? = nil,
                   @ViewBuilder accessory: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            HStack(spacing: Theme.Spacing.s) {
                Group {
                    if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
                }
                .font(.headline)
                Spacer(minLength: 0)
                accessory()
            }
            self
        }
    }
}

// MARK: - Segmented picker

/// The compact segmented switch every heading, card and toolbar uses to change what
/// a view shows.
struct SegmentedPicker<Value: Hashable>: View {
    private let title: String
    @Binding private var selection: Value
    private let options: [Value]
    private let label: (Value) -> String

    init(_ title: String, selection: Binding<Value>, options: [Value], label: @escaping (Value) -> String) {
        self.title = title
        self._selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.self) { Text(label($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}
