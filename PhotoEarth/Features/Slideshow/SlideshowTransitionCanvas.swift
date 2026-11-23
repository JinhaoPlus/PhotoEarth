import AVFoundation
import CoreImage
import SwiftUI
import UIKit

struct SlideshowCanvasPage {
    let descriptor: SlideshowPageDescriptor
    let record: PhotoAssetRecord
    let visit: TravelPlace
    let tiles: [SlideshowCollageFrames.Tile]
}

struct SlideshowMediaTimeline: View {
    @ObservedObject var coordinator: EarthSlideshowCoordinator
    @ObservedObject var playback: PhotoDetailPlaybackModel
    let onDisplay: (String) -> Void

    var body: some View {
        TimelineView(.animation(paused: coordinator.activeTransition == nil || coordinator.isPaused)) { clock in
            let progress = coordinator.transitionProgress(at: clock.date)
            ZStack {
                if let page = coordinator.canvasPage {
                    let id = page.descriptor.ids.first
                    let effect = coordinator.activeTransition
                    let ids = page.descriptor.ids
                    GeometryReader { geometry in
                        let visibleTiles = effect?.visibleTiles(at: progress, ratios: page.descriptor.ratios, in: geometry.size) ?? []
                        SlideshowTransitionCanvas(page: page, effect: effect,
                            progress: progress, waiting: coordinator.phase == .transitioningItem && coordinator.activeTransition == nil,
                            player: playback.preparedAssetID == id ? playback.player : nil,
                            onVideoDisplay: { if let id { onDisplay(id) } })
                            .onChange(of: visibleTiles) { _, indices in coordinator.markTilesVisible(ids, indices: indices) }
                    }
                }
                if let id = coordinator.currentItem?.id, playback.preparedAssetID == id,
                   let live = playback.livePhoto {
                    LivePhotoPlaybackView(livePhoto: live, command: playback.liveCommand, playbackModel: playback,
                        isMuted: playback.isMuted, onDisplay: { onDisplay(id) })
                        .opacity(coordinator.canvasPage?.descriptor.ids == [id] ? EarthSlideshowTransition.smooth(progress) : 0.001)
                }
            }
        }
    }
}

/// Only pixels participate in a page change. Captions, focus and MapKit stay
/// outside this surface. The coordinator supplies progress from its playback clock.
struct SlideshowTransitionCanvas: UIViewRepresentable {
    let page: SlideshowCanvasPage
    let effect: EarthSlideshowTransition?
    let progress: Double
    let waiting: Bool
    let player: AVPlayer?
    let onVideoDisplay: () -> Void

    func makeUIView(context: Context) -> Stage { Stage() }

    func updateUIView(_ stage: Stage, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.display(page, effect: effect, progress: progress, waiting: waiting)
        if let player { stage.installVideo(player, onDisplay: onVideoDisplay) }
        CATransaction.commit()
    }

    final class Stage: UIView {
        private var old: UIView?
        private var incoming: PhotoPlane?
        private let feather = CAGradientLayer()
        private let centerMask = CAGradientLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            clipsToBounds = true
            isUserInteractionEnabled = false
            centerMask.startPoint = CGPoint(x: 0, y: 0.5)
            centerMask.endPoint = CGPoint(x: 1, y: 0.5)
            centerMask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
            centerMask.locations = [0, 0.025, 0.975, 1]
            feather.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
        }
        required init?(coder: NSCoder) { nil }

        func display(_ page: SlideshowCanvasPage, effect: EarthSlideshowTransition?, progress: Double, waiting: Bool) {
            if incoming?.descriptor != page.descriptor {
                let interrupted = old != nil && effect != nil ? snapshotView(afterScreenUpdates: false) : nil
                // A split backdrop can be temporarily hosted beneath the outgoing foreground.
                incoming?.restoreBackground()
                old?.removeFromSuperview()
                if let interrupted {
                    incoming?.removeFromSuperview()
                    old = interrupted
                    addSubview(interrupted)
                } else {
                    old = incoming
                }
                let next = PhotoPlane(page: page)
                incoming = next
                addSubview(next)
                old?.frame = bounds
                next.frame = bounds
                next.layoutIfNeeded()
            } else {
                incoming?.upgradeSingle(page.tiles.first?.image)
            }
            guard let incoming else { return }
            // Freeze the displayed mix while the newly requested page loads.
            if waiting { return }
            guard let effect, let old, progress < 1 else {
                finish()
                return
            }
            let blend = EarthSlideshowTransition.smooth(progress)
            switch effect.kind {
            case .dissolve, .settle:
                incoming.alpha = blend
                if effect.kind == .settle {
                    let scale = 1 - 0.018 * pow(1 - progress, 3)
                    incoming.foreground.transform = CGAffineTransform(scaleX: scale, y: scale)
                }
            case .panoramaGlide:
                (old as? PhotoPlane)?.foreground.transform = CGAffineTransform(translationX: -bounds.width * 0.08 * blend, y: 0)
                incoming.foreground.transform = CGAffineTransform(translationX: bounds.width * 0.12 * (1 - blend), y: 0)
                incoming.alpha = blend
            case .focusPullback:
                let scale = 1 + 0.12 * (1 - blend)
                incoming.foreground.transform = CGAffineTransform(scaleX: scale, y: scale)
                incoming.alpha = blend
            case .centerOpen:
                // Overscan just the feathered mask so the outer tiles finish fully opaque.
                centerMask.frame = effect.openingRect(at: progress, in: bounds)
                incoming.layer.mask = centerMask
            case .reveal:
                let edge = 1.5 * blend
                feather.frame = bounds
                feather.startPoint = CGPoint(x: edge - 0.5, y: 0.5)
                feather.endPoint = CGPoint(x: edge, y: 0.5)
                incoming.layer.mask = feather
            case .backdrop:
                guard let previous = old as? PhotoPlane else { incoming.alpha = blend; return }
                if incoming.backdrop.superview !== self { insertSubview(incoming.backdrop, at: 0) }
                previous.backdrop.alpha = 1 - EarthSlideshowTransition.smooth(progress / 0.65)
                let fg = EarthSlideshowTransition.smooth((progress - 0.2) / 0.8)
                previous.foreground.alpha = 1 - fg
                incoming.foreground.alpha = fg
            case .stagger:
                incoming.backdrop.alpha = 0
                for (index, tile) in incoming.images.enumerated() {
                    tile.alpha = effect.tileOpacity(at: progress, index: index, count: incoming.images.count)
                }
            }
        }

        private func finish() {
            guard let incoming, old != nil else { return }
            old?.removeFromSuperview()
            old = nil
            incoming.restoreBackground()
            incoming.layer.mask = nil
            incoming.alpha = 1
            incoming.foreground.alpha = 1
            incoming.foreground.transform = .identity
            incoming.backdrop.alpha = 1
            for tile in incoming.images { tile.alpha = 1 }
        }

        func installVideo(_ player: AVPlayer, onDisplay: @escaping () -> Void) {
            incoming?.installVideo(player, onDisplay: onDisplay)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            old?.frame = bounds
            incoming?.frame = bounds
            if incoming?.backdrop.superview === self { incoming?.backdrop.frame = bounds }
            feather.frame = bounds
        }
    }

    private final class PhotoPlane: UIView {
        let descriptor: SlideshowPageDescriptor
        let backdrop = UIView()
        let foreground = UIView()
        private let wash = UIImageView()
        private let shade = CAGradientLayer()
        private var video: PhotoVideoPlaybackView.PlayerView?
        private(set) var images: [UIImageView] = []
        private static let context = CIContext(options: [.cacheIntermediates: false])

        init(page: SlideshowCanvasPage) {
            descriptor = page.descriptor
            super.init(frame: .zero)
            clipsToBounds = true
            backdrop.backgroundColor = .black
            backdrop.clipsToBounds = true
            addSubview(backdrop)
            addSubview(foreground)
            if descriptor.ids.count == 1 {
                wash.contentMode = .scaleAspectFill
                wash.alpha = 0.32
                backdrop.addSubview(wash)
                shade.colors = [UIColor.black.withAlphaComponent(0.20).cgColor, UIColor.clear.cgColor,
                                UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.28).cgColor]
                shade.locations = [0, 0.28, 0.70, 1]
                foreground.layer.addSublayer(shade)
            }
            for tile in page.tiles {
                let image = UIImageView(image: tile.image)
                image.contentMode = .scaleAspectFit
                foreground.insertSubview(image, at: 0)
                images.append(image)
            }
            if images.count == 1 { wash.image = Self.softBackground(images[0].image) }
        }
        required init?(coder: NSCoder) { nil }

        func restoreBackground() {
            if backdrop.superview !== self { insertSubview(backdrop, at: 0) }
        }

        func upgradeSingle(_ image: UIImage?) {
            guard descriptor.ids.count == 1, let image, images.first?.image !== image else { return }
            if let first = images.first { first.image = image }
            else {
                let view = UIImageView(image: image)
                view.contentMode = .scaleAspectFit
                foreground.insertSubview(view, at: 0)
                images = [view]
                setNeedsLayout()
            }
            wash.image = Self.softBackground(image)
        }

        // Blur a small derivative once per rendition instead of filtering a 4K layer on every frame.
        private static func softBackground(_ image: UIImage?) -> UIImage? {
            guard let thumb = image?.preparingThumbnail(of: CGSize(width: 128, height: 128)),
                  let input = CIImage(image: thumb) else { return nil }
            let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 4)
            return context.createCGImage(blurred, from: input.extent).map { UIImage(cgImage: $0, scale: 1, orientation: thumb.imageOrientation) }
        }

        func installVideo(_ player: AVPlayer, onDisplay: @escaping () -> Void) {
            guard video?.playerLayer.player !== player else { return }
            let view = video ?? PhotoVideoPlaybackView.PlayerView()
            view.cancelDisplayObservation()
            view.playerLayer.videoGravity = .resizeAspect
            view.playerLayer.player = player
            view.frame = bounds
            foreground.addSubview(view)
            video = view
            view.observeDisplay(ifNeeded: onDisplay)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            backdrop.frame = bounds
            foreground.bounds = bounds
            foreground.center = CGPoint(x: bounds.midX, y: bounds.midY)
            wash.frame = bounds
            shade.frame = bounds
            video?.frame = bounds
            guard images.count > 1 else { images.first?.frame = bounds; return }
            let frames = SlideshowCollageLayout.frames(for: descriptor.ratios, in: bounds.size)
            for (image, frame) in zip(images, frames) { image.frame = frame }
        }
    }
}
