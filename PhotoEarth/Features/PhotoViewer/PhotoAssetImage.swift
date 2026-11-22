import SwiftUI
import UIKit
import Photos

struct PhotoAssetImage: View {
    let assetID: String
    var contentMode: ContentMode = .fill
    // A wall may crop the display while passing a full-composition preview to detail.
    var displayContentMode: ContentMode?
    var targetSize = CGSize(width: 1_000, height: 700)
    var allowsRetry = false
    var isActive = true
    var priority: PhotoImagePriority = .visible
    var usesOriginalCover = false
    var initialImage: UIImage?
    var onImageChange: ((UIImage?) -> Void)?
    var onRetryVisibilityChange: ((Bool) -> Void)?

    @StateObject private var loader = PhotoImageLoader()
    @State private var removedAssetID: String?
    @State private var contentRevision: UInt64 = 0
    @State private var deferredRelease: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    private struct RequestKey: Hashable {
        let assetID: String
        let width: CGFloat
        let height: CGFloat
        let fillsTarget: Bool
        let isActive: Bool
        let usesOriginalCover: Bool
        let contentRevision: UInt64
    }

    private var requestKey: RequestKey {
        RequestKey(assetID: assetID, width: targetSize.width, height: targetSize.height,
                   fillsTarget: contentMode == .fill, isActive: isActive && scenePhase == .active,
                   usesOriginalCover: usesOriginalCover, contentRevision: contentRevision)
    }

    private var isRemoved: Bool { removedAssetID == assetID }
    private var currentImage: UIImage? { loader.loadedAssetID == assetID ? loader.image : nil }
    private var usesSampleArtwork: Bool {
        currentImage == nil && initialImage == nil && assetID.hasPrefix("sample-")
            && SamplePhotoResource.resourceName(for: assetID) == nil && assetID != "sample-reykjavik-1"
    }
    private var retryVisible: Bool {
        allowsRetry && requestKey.isActive && !isRemoved && !usesSampleArtwork
            && loader.shouldOfferRetry(for: assetID)
    }

    var body: some View {
        Group {
            if isRemoved || !isActive {
                Color.black
            } else if let image = currentImage ?? initialImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: displayContentMode ?? contentMode)
            } else if usesSampleArtwork {
                SamplePhotoArtwork(seed: assetID)
            } else if usesOriginalCover {
                WaitingCoverView()
            } else {
                ZStack {
                    Color.white.opacity(0.06)
                    if loader.loadedAssetID != assetID || loader.isLoading {
                        ProgressView()
                    } else if retryVisible {
                        VStack(spacing: 24) {
                            Text(AppLocalization.string("photo.load_failed", defaultValue: "Photo unavailable"))
                                .font(.system(size: 29, weight: .medium))
                            Text(AppLocalization.string("photo.check_connection", defaultValue: "Check your connection and try again"))
                                .font(.system(size: 23))
                                .foregroundStyle(.secondary)
                            Button(AppLocalization.string("common.reload", defaultValue: "Reload"), action: load)
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("photo-image-retry")
                        }
                    } else {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }
        }
        .clipped()
        .overlay(alignment: .bottom) {
            if retryVisible, (currentImage != nil || initialImage != nil) {
                HStack(spacing: 24) {
                    Text(AppLocalization.string("photo.full_load_failed", defaultValue: "Full photo unavailable"))
                        .font(.system(size: 23))
                    Button(AppLocalization.string("common.reload", defaultValue: "Reload"), action: load)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("photo-image-retry")
                }
                .padding(24)
                .floatingSurface(in: RoundedRectangle(cornerRadius: 18))
                .padding(.bottom, 60)
            }
        }
        .task(id: requestKey) {
            if requestKey.isActive { load() }
            else { loader.cancel(); onImageChange?(nil) }
        }
        .onChange(of: priority) { _, priority in
            guard requestKey.isActive, !isRemoved, loader.loadedAssetID == assetID else { return }
            loader.updatePriority(priority)
        }
        .onChange(of: loader.image) { _, image in onImageChange?(image) }
        .onChange(of: retryVisible, initial: true) { _, visible in onRetryVisibilityChange?(visible) }
        .onAppear {
            deferredRelease?.cancel()
            deferredRelease = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: PhotoAssetChangeNotice.name)) { notice in
            if let removed = notice.userInfo?["removed"] as? Set<String>, removed.contains(assetID) {
                removedAssetID = assetID; loader.cancel(); onImageChange?(nil)
            } else if let changed = notice.userInfo?["changed"] as? Set<String>, changed.contains(assetID) {
                removedAssetID = nil
                if usesOriginalCover {
                    loader.suspend()
                } else {
                    loader.cancel(); onImageChange?(nil)
                }
                // SwiftUI owns this reload with the current asset identity; a
                // deferred closure for an old photo cannot replace a new request.
                contentRevision &+= 1
            }
        }
        .onDisappear {
            // Lazy stacks can declare an edge cell disappeared before its
            // outgoing scroll pixels have left the clipped viewport. Cancel
            // PhotoKit immediately, but retain the decoded frame through that
            // short handoff so the visible edge never turns into a placeholder.
            loader.suspend()
            onImageChange?(nil)
            onRetryVisibilityChange?(false)
            deferredRelease?.cancel()
            deferredRelease = Task { @MainActor [loader] in
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled else { return }
                loader.cancel()
            }
        }
    }

    private func load() {
        guard isActive, scenePhase == .active, !isRemoved else { loader.cancel(); return }
        loader.load(assetID: assetID, targetSize: targetSize,
                    contentMode: contentMode == .fit ? .aspectFit : .aspectFill,
                    initialImage: initialImage, priority: priority, usesOriginal: usesOriginalCover)
    }
}

@MainActor enum PhotoAssetChangeNotice {
    static let name = Notification.Name("PhotoEarth.privateAssetMetadataChanged")
    static func post(changed: Set<String>, removed: Set<String>) {
        guard !changed.isEmpty || !removed.isEmpty else { return }
        SharedPhotoImageScheduler.shared.invalidate(changed.union(removed))
        NotificationCenter.default.post(name: name, object: nil, userInfo: ["changed": changed, "removed": removed])
    }
}

struct SamplePhotoArtwork: View {
    let seed: String

    private var palette: [Color] {
        let value = seed.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let palettes: [[Color]] = [
            [.indigo, .cyan, .mint],
            [.orange, .pink, .purple],
            [.blue, .teal, .yellow],
            [.purple, .blue, .black],
            [.red, .orange, .yellow],
        ]
        return palettes[value % palettes.count]
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle()
                    .fill(.white.opacity(0.17))
                    .frame(width: proxy.size.width * 0.48)
                    .blur(radius: 8)
                    .offset(x: proxy.size.width * 0.24, y: -proxy.size.height * 0.18)
                WaveShape()
                    .fill(.black.opacity(0.28))
                    .frame(height: proxy.size.height * 0.46)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

private struct WaveShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.height * 0.58))
        path.addCurve(
            to: CGPoint(x: rect.width, y: rect.height * 0.25),
            control1: CGPoint(x: rect.width * 0.28, y: -rect.height * 0.08),
            control2: CGPoint(x: rect.width * 0.65, y: rect.height * 0.95)
        )
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}
