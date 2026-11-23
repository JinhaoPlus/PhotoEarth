import SwiftUI

struct EarthEntryButton: View {
    enum Kind { case explore, slideshow }

    let kind: Kind
    let title: String
    var minimumHeight: CGFloat = 78
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Group {
                    switch kind {
                    case .explore: ExploreGlobeSymbol()
                    case .slideshow: SlideshowSymbol()
                    }
                }
                .accessibilityHidden(true)
                Text(verbatim: title)
                    .font(.system(size: 27, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.leading, 14)
            .padding(.trailing, 26)
            .frame(minHeight: minimumHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(EarthEntryStyle())
        .focusEffectDisabled()
    }
}

private struct EarthEntryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration)
    }

    private struct Surface: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .foregroundStyle(focused ? Color.black : .white)
                .background {
                    if focused {
                        Capsule().fill(.white)
                    } else {
                        Capsule().fill(LinearGradient(colors: [
                            Color(red: 0.12, green: 0.29, blue: 0.39),
                            Color(red: 0.07, green: 0.14, blue: 0.23)
                        ], startPoint: .leading, endPoint: .trailing))
                    }
                }
                .overlay { Capsule().strokeBorder(.white.opacity(focused ? 1 : 0.32), lineWidth: focused ? 2 : 1) }
                .shadow(color: .black.opacity(0.32), radius: 6, y: 3)
                .scaleEffect(focused && !reduceMotion ? 1.035 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: focused)
                .opacity(!enabled ? 0.45 : configuration.isPressed ? 0.82 : 1)
        }
    }
}
