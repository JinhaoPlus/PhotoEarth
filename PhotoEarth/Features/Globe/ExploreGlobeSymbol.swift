import SwiftUI

struct ExploreGlobeSymbol: View {
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(
                colors: [Color(red: 0.15, green: 0.48, blue: 0.64),
                         Color(red: 0.03, green: 0.13, blue: 0.28)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            Image(systemName: "globe.europe.africa.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(LinearGradient(
                    colors: [Color(red: 0.82, green: 0.96, blue: 0.83),
                             Color(red: 0.35, green: 0.71, blue: 0.70)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.85), .clear],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing),
                                  lineWidth: 1.5)
        }
        .frame(width: 44, height: 44)
    }
}
