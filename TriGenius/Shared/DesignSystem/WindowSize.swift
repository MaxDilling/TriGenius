import SwiftUI

// MARK: - The window's size, as an environment value
//
// SwiftUI hands a presented sheet nothing about the window it is attached to:
// `PresentationSizingContext` is empty, and every `presentationSizing` option
// resolves to a fixed size — `.fitted`, the macOS default, to the smallest one
// its content will accept. So the size is measured where it *is* known, at the
// scene's root, and read back wherever layout has to scale with the window
// instead of with its own container.

extension EnvironmentValues {
    /// The scene root's size — the window's content area on macOS, the screen on
    /// iOS. `.zero` until the first layout pass.
    @Entry var windowSize: CGSize = .zero
}

extension View {
    /// Publish this view's size as `\.windowSize` to everything below it,
    /// sheets included. Belongs on the scene's root view and nowhere else.
    func measuringWindow() -> some View {
        modifier(WindowSizeReader())
    }

    /// A sheet that takes most of the window — for a chart or map worth the
    /// room. Put on the sheet's content.
    func windowFillingSheet() -> some View {
        modifier(WindowFillingSheet())
    }
}

private struct WindowFillingSheet: ViewModifier {
    @Environment(\.windowSize) private var windowSize

    func body(content: Content) -> some View {
        #if os(macOS)
        // Without an explicit size the sheet takes the smallest one its content
        // accepts; a fixed one overflows a small window and wastes a large one.
        // `.zero` only before the root's first layout pass.
        let size = windowSize.width > 0
            ? CGSize(width: windowSize.width * 0.92, height: windowSize.height * 0.88)
            : CGSize(width: 900, height: 600)
        content.frame(width: size.width, height: size.height)
        #else
        // A frame cannot resize a sheet here — the presentation owns the size —
        // and iPadOS defaults to `.form`, small and centred. `.page` hands the
        // content the screen; on iPhone it is the usual sheet.
        content.presentationSizing(.page)
        #endif
    }
}

private struct WindowSizeReader: ViewModifier {
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .environment(\.windowSize, size)
    }
}
