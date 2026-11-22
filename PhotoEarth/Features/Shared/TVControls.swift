import SwiftUI

enum TVControlLayout {
    /// Breathing room for native glass buttons and their focus enlargement.
    static let actionSpacing: CGFloat = 20
    /// Custom toolbar buttons draw their focus inside their own bounds.
    static let toolbarSpacing: CGFloat = 10
}

/// Keeps text and symbol spacing consistent in page actions.
struct PageActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.font(.system(size: 22, weight: .medium))
            configuration.title
                .font(.system(size: 25, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 52)
    }
}

/// The same play/pause silhouette works over a photograph or inside the transport bar.
struct PlaybackButtonFace: View {
    let symbol: String
    let isFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 25, weight: .semibold))
            .offset(x: symbol == "play.fill" ? 1.5 : 0)
            .foregroundStyle(isFocused ? .black : .white)
            .frame(width: 64, height: 64)
            .background {
                Circle().fill(isFocused ? Color.white : Color(white: 0.16).opacity(reduceTransparency ? 1 : 0.9))
            }
            .overlay {
                Circle().strokeBorder(.white.opacity(isFocused ? 1 : 0.45), lineWidth: isFocused ? 2 : 1)
            }
            .shadow(color: .black.opacity(0.32), radius: 5, y: 2)
            .contentShape(Circle())
    }
}

/// Two visible choices share one focus target. Select moves the highlighted segment.
struct TwoOptionControlLabel<First: View, Second: View>: View {
    let secondSelected: Bool
    let focused: Bool
    let segmentSize: CGSize
    @ViewBuilder let first: () -> First
    @ViewBuilder let second: () -> Second
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            segment(selected: !secondSelected, content: first)
            segment(selected: secondSelected, content: second)
        }
        .padding(6)
        .background(reduceTransparency ? Color(white: 0.08) : .black.opacity(0.22), in: Capsule())
        .overlay { Capsule().strokeBorder(.white.opacity(focused ? 0.95 : 0.16), lineWidth: focused ? 2 : 1) }
        .shadow(color: .cyan.opacity(focused && !reduceTransparency ? 0.20 : 0), radius: 14)
        .contentShape(Capsule())
        .scaleEffect(focused && !reduceMotion ? 1.025 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: focused)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: secondSelected)
    }

    private func segment<Content: View>(selected: Bool, @ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.system(size: 23, weight: selected ? .semibold : .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: segmentSize.width, height: segmentSize.height)
            .foregroundStyle(selected ? Color(white: 0.10) : .white.opacity(focused ? 0.82 : 0.62))
            .background {
                if selected {
                    let pill = Capsule().fill(reduceTransparency ? .white : .white.opacity(focused ? 0.96 : 0.82))
                    if reduceMotion { pill }
                    else { pill.matchedGeometryEffect(id: "selection", in: selection) }
                }
            }
    }
}
