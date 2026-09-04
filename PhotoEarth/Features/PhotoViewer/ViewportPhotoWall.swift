import SwiftUI

struct ViewportPhotoWall: View {
    let records: [PhotoAssetRecord]
    let isLoading: Bool
    let hasMore: Bool
    let labels: [String: PlaceDisplayLabel]
    let selectPhoto: (PhotoAssetRecord) -> Void
    let loadMore: () -> Void
    let close: () -> Void

    @FocusState private var focusedPhotoID: String?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 24), count: 4)

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 64)
                .padding(.vertical, 26)

            ScrollView {
                if records.isEmpty && !isLoading {
                    VStack(spacing: 16) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 38, weight: .light))
                            .foregroundStyle(.cyan.opacity(0.7))
                        Text("这片地表暂时没有带位置的照片")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                        Text("返回地球，移动或缩放到另一片区域再试试")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 155)
                } else {
                    LazyVGrid(columns: columns, spacing: 25) {
                        ForEach(records) { record in
                            photoButton(record)
                        }
                    }
                    .padding(.horizontal, 64)
                    .padding(.bottom, 38)
                }

                if isLoading {
                    ProgressView("正在展开更多记忆…")
                        .tint(.cyan)
                        .foregroundStyle(.white.opacity(0.62))
                        .padding(.bottom, 60)
                } else if hasMore {
                    Color.clear
                        .frame(height: 80)
                        .onAppear(perform: loadMore)
                } else if !records.isEmpty {
                    Text("已经抵达这片地表记忆的尽头")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.bottom, 55)
                }
            }
        }
        .background(.black.opacity(0.83))
        .background(.ultraThinMaterial.opacity(0.35))
        .overlay {
            LinearGradient(
                colors: [.cyan.opacity(0.07), .clear, .black.opacity(0.24)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .allowsHitTesting(false)
        }
        .onAppear(perform: focusFirstPhoto)
        .onChange(of: records.first?.id) { _, _ in focusFirstPhoto() }
        .onExitCommand(perform: close)
        .accessibilityIdentifier("viewport-photo-wall")
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 11) {
                    Circle()
                        .fill(.cyan)
                        .frame(width: 7, height: 7)
                        .shadow(color: .cyan, radius: 7)
                    Text("当前地表的记忆")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                }
                Text(records.isEmpty && isLoading ? "正在圈定照片…" : "已加载 \(records.count) 张 · 向下浏览会继续加载")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.48))
            }

            Spacer()

            Label("返回地球", systemImage: "chevron.down")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.54))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.white.opacity(0.07), in: Capsule())
        }
    }

    private func photoButton(_ record: PhotoAssetRecord) -> some View {
        Button { selectPhoto(record) } label: {
            ZStack(alignment: .bottomLeading) {
                PhotoAssetImage(
                    assetID: record.id,
                    targetSize: CGSize(width: 720, height: 450)
                )

                LinearGradient(
                    colors: [.clear, .black.opacity(0.72)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(placeName(for: record))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                        Text(record.creationDate.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    Spacer()
                    if record.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.pink)
                    }
                }
                .padding(14)
            }
            .frame(height: 216)
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.card)
        .focused($focusedPhotoID, equals: record.id)
        .accessibilityIdentifier("viewport-photo-\(record.id)")
    }

    private func placeName(for record: PhotoAssetRecord) -> String {
        guard let placeID = record.placeID else { return "旅行记忆" }
        return labels[placeID]?.city ?? "旅行记忆"
    }

    private func focusFirstPhoto() {
        guard focusedPhotoID == nil, let firstID = records.first?.id else { return }
        Task { @MainActor in
            await Task.yield()
            focusedPhotoID = firstID
        }
    }
}
