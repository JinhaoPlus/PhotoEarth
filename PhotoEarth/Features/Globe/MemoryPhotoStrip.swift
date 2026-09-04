import SwiftUI

struct MemoryPhotoStrip: View {
    let records: [PhotoAssetRecord]
    let isManipulating: Bool
    let isRefreshing: Bool

    @StateObject private var thumbnailStore = MemoryThumbnailStore()

    private var displayedRecords: [PhotoAssetRecord] {
        Array(records.prefix(8))
    }

    private var contentSignature: String {
        displayedRecords.map(\.id).joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                Circle()
                    .fill(isManipulating ? .white.opacity(0.36) : .cyan)
                    .frame(width: 7, height: 7)
                    .shadow(color: isManipulating ? .clear : .cyan, radius: 7)

                Text(isManipulating ? "地球转动中" : "此刻俯瞰到的记忆")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .tracking(1.2)

                if !isManipulating, !records.isEmpty {
                    Text("精选 \(records.count) 张")
                        .font(.system(size: 15, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.48))
                }

                if isRefreshing, !isManipulating {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.cyan)
                }
            }
            .foregroundStyle(.white.opacity(isManipulating ? 0.48 : 0.82))

            ZStack(alignment: .leading) {
                if displayedRecords.isEmpty {
                    emptyState
                } else {
                    HStack(spacing: 13) {
                        ForEach(displayedRecords) { record in
                            thumbnail(for: record)
                        }
                    }
                    .id(contentSignature)
                    .transition(.opacity.combined(with: .offset(y: 10)))
                }
            }
            .frame(height: 118, alignment: .leading)
            .animation(.easeOut(duration: 0.42), value: contentSignature)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 62)
        .padding(.top, 24)
        .padding(.bottom, 42)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.58), .black.opacity(0.94)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .opacity(isManipulating ? 0.48 : 1)
        .animation(.easeOut(duration: 0.24), value: isManipulating)
        .allowsHitTesting(false)
        .accessibilityIdentifier("memory-horizon")
        .onAppear(perform: refreshThumbnails)
        .onChange(of: displayedRecords.map(\.id)) { _, _ in refreshThumbnails() }
        .onChange(of: isManipulating) { _, moving in
            if moving {
                thumbnailStore.cancel()
            }
        }
        .onDisappear { thumbnailStore.cancel() }
    }

    @ViewBuilder
    private func thumbnail(for record: PhotoAssetRecord) -> some View {
        Group {
            if record.id.hasPrefix("sample-") {
                SamplePhotoArtwork(seed: record.id)
            } else if let image = thumbnailStore.images[record.id] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.055)
                    Image(systemName: "photo")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.white.opacity(0.24))
                }
            }
        }
        .frame(width: 188, height: 118)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.13), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.42), radius: 12, y: 7)
    }

    private var emptyState: some View {
        HStack(spacing: 14) {
            Image(systemName: "viewfinder")
                .font(.system(size: 28, weight: .light))
            Text(isRefreshing ? "正在寻找这片地表的照片…" : "这片地表暂时没有旅行照片")
                .font(.system(size: 18, weight: .medium, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.42))
        .frame(height: 118)
    }

    private func refreshThumbnails() {
        thumbnailStore.load(
            records: displayedRecords,
            targetSize: CGSize(width: 420, height: 264)
        )
    }
}
