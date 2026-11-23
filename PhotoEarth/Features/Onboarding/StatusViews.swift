import SwiftUI

struct ScanningView: View {
    var body: some View {
        ZStack {
            SpaceBackdrop()
            VStack(spacing: 30) {
                ProgressView()
                    .controlSize(.extraLarge)
                    .tint(.cyan)
                Text(AppLocalization.string("scanning.title", defaultValue: "Opening PHOTO EARTH…"))
                    .font(.largeTitle.bold())
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
                HStack(spacing: TVControlLayout.actionSpacing) {
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
