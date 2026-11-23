import SwiftUI

struct EarthSlideshowEntryButton: View {
    var title = AppLocalization.string("slideshow.start", defaultValue: "Slideshow")
    var minimumHeight: CGFloat = 78
    let action: () -> Void

    var body: some View {
        EarthEntryButton(kind: .slideshow, title: title, minimumHeight: minimumHeight, action: action)
    }
}

struct SlideshowSymbol: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: 0.64, green: 0.42, blue: 0.28))
                .frame(width: 32, height: 24)
                .rotationEffect(.degrees(-10))
                .offset(x: -3, y: -3)
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [Color(red: 1, green: 0.92, blue: 0.75),
                                                  Color(red: 0.93, green: 0.71, blue: 0.47)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(red: 0.21, green: 0.14, blue: 0.12))
                    .offset(x: 1)
            }
            .frame(width: 34, height: 25)
            .offset(x: 2, y: 3)
        }
        .frame(width: 44, height: 44)
    }
}
