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
}

private struct WindowSizeReader: ViewModifier {
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .environment(\.windowSize, size)
    }
}
