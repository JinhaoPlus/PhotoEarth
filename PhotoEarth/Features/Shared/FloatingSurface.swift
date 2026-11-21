import SwiftUI

extension View {
    /// Use on the fitted panel, before adding its screen-edge margins.
    func floatingSurface<S: Shape>(in shape: S) -> some View {
        modifier(FloatingSurface(shape: shape))
    }
}

private struct FloatingSurface<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency { shape.fill(Color(white: 0.10)) }
            }
            .glassEffect(reduceTransparency ? .identity : .regular, in: shape)
    }
}
