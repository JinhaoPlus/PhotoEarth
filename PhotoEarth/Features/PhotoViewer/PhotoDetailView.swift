import SwiftUI

struct PhotoDetailView: View {
    let record: PhotoAssetRecord
    let placeLabel: PlaceDisplayLabel?
    let close: () -> Void

    @State private var showsInformation = false
    @FocusState private var isInfoButtonFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.97)

            PhotoAssetImage(
                assetID: record.id,
                contentMode: .fit,
                targetSize: CGSize(width: 3_840, height: 2_160)
            )
            .padding(.horizontal, showsInformation ? 245 : 78)
            .padding(.vertical, 54)
            .animation(.easeInOut(duration: 0.32), value: showsInformation)

            LinearGradient(
                colors: [.black.opacity(0.58), .clear, .clear, .black.opacity(0.34)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack {
                HStack(alignment: .top) {
                    Label("返回照片墙", systemImage: "chevron.left")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(.black.opacity(0.45), in: Capsule())

                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showsInformation.toggle()
                        }
                    } label: {
                        Label(
                            showsInformation ? "收起信息" : "照片信息",
                            systemImage: showsInformation ? "sidebar.right" : "info.circle"
                        )
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.black.opacity(0.58))
                    .focused($isInfoButtonFocused)
                    .accessibilityIdentifier("photo-information-toggle")
                }
                .padding(.horizontal, 56)
                .padding(.top, 40)

                Spacer()
            }

            if showsInformation {
                HStack {
                    Spacer()
                    informationPanel
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                isInfoButtonFocused = true
            }
        }
        .onExitCommand(perform: close)
        .accessibilityIdentifier("photo-detail")
    }

    private var informationPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            Text("PHOTO MEMORY")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(4)
                .foregroundStyle(.cyan)
                .padding(.bottom, 13)

            Text(placeLabel?.city ?? "旅行记忆")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .lineLimit(2)

            if let country = placeLabel?.country {
                Text(country)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.56))
                    .padding(.top, 5)
            }

            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(height: 1)
                .padding(.vertical, 24)

            informationRow(
                icon: "calendar",
                title: "拍摄时间",
                value: record.creationDate.formatted(date: .long, time: .shortened)
            )
            informationRow(
                icon: "mappin.and.ellipse",
                title: "地理位置",
                value: String(
                    format: "%.4f°,  %.4f°",
                    record.coordinate.latitude,
                    record.coordinate.longitude
                )
            )
            informationRow(
                icon: "aspectratio",
                title: "照片尺寸",
                value: "\(record.pixelWidth) × \(record.pixelHeight)"
            )
            informationRow(
                icon: record.isFavorite ? "heart.fill" : "heart",
                title: "收藏状态",
                value: record.isFavorite ? "已收藏" : "未收藏"
            )

            Spacer()

            Text("照片来自你的 iCloud Photos，Photo Earth 不会复制或修改原图。")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.36))
                .lineSpacing(4)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 52)
        .frame(width: 430)
        .background(.black.opacity(0.86))
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) {
            LinearGradient(
                colors: [.clear, .cyan.opacity(0.38), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: 1)
        }
        .ignoresSafeArea()
    }

    private func informationRow(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.cyan.opacity(0.78))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.38))
                Text(value)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.84))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 22)
    }
}
