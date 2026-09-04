import SwiftUI

struct ScanningView: View {
    var body: some View {
        ZStack {
            SpaceBackdrop()
            VStack(spacing: 30) {
                ProgressView()
                    .controlSize(.extraLarge)
                    .tint(.cyan)
                Text("正在整理你的旅行地球…")
                    .font(.largeTitle.bold())
                Text("我们只索引带有地点信息的照片。首次扫描可能需要一点时间。")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct MessageView: View {
    let symbol: String
    let title: String
    let message: String
    let primaryTitle: String
    let primaryAction: () -> Void
    let secondaryTitle: String?
    let secondaryAction: (() -> Void)?

    var body: some View {
        ZStack {
            SpaceBackdrop()
            VStack(spacing: 22) {
                Image(systemName: symbol)
                    .font(.system(size: 76, weight: .light))
                    .foregroundStyle(.cyan)
                Text(title)
                    .font(.largeTitle.bold())
                Text(message)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 800)
                HStack(spacing: 24) {
                    Button(primaryTitle, action: primaryAction)
                        .buttonStyle(.borderedProminent)
                    if let secondaryTitle, let secondaryAction {
                        Button(secondaryTitle, action: secondaryAction)
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.top, 18)
            }
        }
    }
}
