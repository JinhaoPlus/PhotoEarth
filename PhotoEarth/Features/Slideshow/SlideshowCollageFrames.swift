import UIKit

/// Resolve only the local rendition of a proposed row. A missing tile ends
/// the usable prefix. Cloud recovery belongs to the ordinary single-photo path.
@MainActor final class SlideshowCollageFrames {
    struct Tile: Identifiable {
        let id: String
        let ratio: CGFloat
        let image: UIImage
    }

    static var displayPixels: CGSize {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.screen.nativeBounds.size ?? SlideshowCollageLayout.television
    }

    private let scheduler: SharedPhotoImageScheduler
    private var requests: [UUID] = []
    private var deadline: Task<Void, Never>?
    private var generation = UUID()

    init(scheduler: SharedPhotoImageScheduler? = nil) { self.scheduler = scheduler ?? .shared }

    func load(_ members: [EarthSlideshowCoordinator.FilmstripItem], canvas: CGSize, priority: PhotoImagePriority = .focus,
              completion: @escaping ([Tile]) -> Void) {
        cancel()
        let token = generation
        let sizes = SlideshowCollageLayout.sizes(for: members.map(\.ratio), in: canvas)
        var ready: [String: Tile] = [:]
        var missing = Set<String>()
        func finish() {
            guard generation == token else { return }
            let prefix = members.prefix { ready[$0.id] != nil }.compactMap { ready[$0.id] }
            let count = SlideshowCollageLayout.count(for: prefix.map(\.ratio), in: canvas)
            cancel()
            completion(Array(prefix.prefix(count)))
        }
        for (member, size) in zip(members, sizes) {
            guard generation == token else { break }
            let request = UUID()
            requests.append(request)
            let key = SharedPhotoImageKey(assetID: member.id, targetSize: size, fillsTarget: false)
            scheduler.request(key, network: false, priority: priority, token: request) { [weak self] delivery in
                guard let self, self.generation == token, delivery.isFinal else { return }
                if let image = delivery.image {
                    ready[member.id] = Tile(id: member.id, ratio: member.ratio, image: image)
                } else {
                    missing.insert(member.id)
                }
                let next = members.first { ready[$0.id] == nil }
                if next == nil || next.map({ missing.contains($0.id) }) == true {
                    finish()
                } else if ready[members[0].id] != nil, self.deadline == nil {
                    // Give local decodes one short handoff once the first tile
                    // is ready. Never hold that photograph for a cloud fetch.
                    self.deadline = Task {
                        do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                        finish()
                    }
                }
            }
        }
    }

    func cancel() {
        generation = UUID()
        deadline?.cancel()
        deadline = nil
        for token in requests { scheduler.cancel(token) }
        requests.removeAll()
    }

    isolated deinit { cancel() }
}
