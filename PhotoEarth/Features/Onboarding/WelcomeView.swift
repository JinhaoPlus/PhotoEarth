import SwiftUI

struct WelcomeView: View {
    let begin: () -> Void
    let showDemo: () -> Void

    var body: some View {
        ZStack {
            SpaceBackdrop()

            HStack(spacing: 90) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.cyan.opacity(0.85), Color.blue.opacity(0.46), Color.black],
                                center: .topLeading,
                                startRadius: 20,
                                endRadius: 290
                            )
                        )
                        .frame(width: 460, height: 460)
                        .shadow(color: .blue.opacity(0.45), radius: 80)

                    ForEach(0..<7, id: \.self) { index in
                        Circle()
                            .fill(index == 0 ? Color.yellow : Color.cyan)
                            .frame(width: index == 0 ? 24 : 14, height: index == 0 ? 24 : 14)
                            .offset(
                                x: cos(Double(index) * 1.37) * 175,
                                y: sin(Double(index) * 1.71) * 150
                            )
                    }
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 24) {
                    Text("PHOTO EARTH")
                        .font(.caption.weight(.semibold))
                        .tracking(8)
                        .foregroundStyle(.cyan)

                    Text("你的旅程，\n落在地球上")
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("读取照片中的地点与时间，在 Apple TV 上生成一颗只属于你的旅行星球。照片不会离开你的照片图库。")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.68))
                        .frame(maxWidth: 650, alignment: .leading)
                        .lineSpacing(7)

                    HStack(spacing: 24) {
                        Button("连接照片图库", action: begin)
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)

                        Button("先看示例旅程", action: showDemo)
                            .buttonStyle(.bordered)
                    }
                    .font(.title3.weight(.semibold))
                    .padding(.top, 16)
                }
            }
            .padding(.horizontal, 120)
        }
    }
}
