import MapKit
import os

/// One in-memory, noninteractive view of the last rendered home globe, including MapKit attribution.
@MainActor
final class HomeGlobeFrame: NSObject {
    enum Context: Equatable {
        case inactive
        case home(String)
        case away(String)

        var revision: String? {
            switch self {
            case .inactive: nil
            case .home(let revision), .away(let revision): revision
            }
        }
    }

    private struct Key: Equatable {
        let revision: String
        let camera: GlobeCameraState
        let bounds: CGRect
        let scale: CGFloat
    }

    private let log = Logger(subsystem: "com.doupi.PhotoEarth.PhotoEarth", category: "HomeGlobeFrame")
    private var home: Key?
    private var renderedHome: Key?
    private var saved: (key: Key, view: UIView)?
    var isShowing: Bool { saved?.view.superview != nil }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(discard), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }

    /// Runs before changing anything on the resident map so the outgoing frame
    /// still has the home camera, annotations, attribution and satellite style.
    func update(in map: MKMapView, context: Context, camera: GlobeCameraState, canCapture: Bool, isDriftStep: Bool = false) -> Bool {
        guard let revision = context.revision else {
            home = nil
            renderedHome = nil
            discard()
            return false
        }
        if let saved, saved.key.revision != revision || saved.key.bounds != map.bounds
            || saved.key.scale != map.traitCollection.displayScale {
            discard()
        }
        if case .home = context {
            let key = Key(revision: revision, camera: camera, bounds: map.bounds, scale: map.traitCollection.displayScale)
            let returning = home == nil && saved?.key == key
            if saved?.key != key { discard() }
            if isDriftStep, let home, renderedHome == home, home.revision == revision,
               home.bounds == key.bounds, home.scale == key.scale {
                renderedHome = key
            } else if home != key {
                renderedHome = nil
            }
            home = key
            return returning
        }

        if let home, home.revision == revision, home.bounds == map.bounds,
           (canCapture || renderedHome == home), map.window != nil, !isShowing,
           let view = map.snapshotView(afterScreenUpdates: false) {
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
            saved = (home, view)
            log.info("Captured the rendered home globe")
        }
        saved?.view.removeFromSuperview()
        home = nil
        renderedHome = nil
        return false
    }

    func show(in map: MKMapView) {
        guard let saved, saved.key == home else { return }
        saved.view.frame = map.bounds
        map.addSubview(saved.view)
        log.info("Restored the rendered home globe")
    }

    func didRender(camera: GlobeCameraState?) {
        guard let home, home.camera == camera else { return }
        renderedHome = home
        guard isShowing else { return }
        saved?.view.removeFromSuperview()
        log.info("Revealed the live home globe")
    }

    @objc private func discard() {
        saved?.view.removeFromSuperview()
        saved = nil
    }
}
