import SwiftUI

struct EarthSlideshowEntryButton: View {
    var minimumHeight: CGFloat = 78
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                earthPlaySymbol.accessibilityHidden(true)
                Text(AppLocalization.string("slideshow.start", defaultValue: "Slideshow"))
                    .font(.system(size: 27, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.leading, 14)
            .padding(.trailing, 26)
            .frame(minHeight: minimumHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(SlideshowEntryStyle())
        .focusEffectDisabled()
    }

    private var earthPlaySymbol: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [
                Color(red: 0.19, green: 0.47, blue: 0.60),
                Color(red: 0.04, green: 0.13, blue: 0.23)
            ], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "globe.europe.africa.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white.opacity(0.20))
            Circle().strokeBorder(LinearGradient(colors: [
                Color(red: 1, green: 0.86, blue: 0.64), .white.opacity(0.08)
            ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
            Image(systemName: "play.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 2)
                .offset(x: 1)
        }
        .frame(width: 44, height: 44)
    }
}

private struct SlideshowEntryStyle: ButtonStyle {
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
