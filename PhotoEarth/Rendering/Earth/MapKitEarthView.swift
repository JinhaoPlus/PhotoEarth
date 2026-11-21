import MapKit
import os
import SwiftUI
import UIKit

enum FullScreenMapLayout {
    static let margins = UIEdgeInsets(top: 24, left: 16, bottom: 24, right: 16)
    // Keep scrolling cards clear of the native ornaments in either corner.
    static let contentHorizontalInset: CGFloat = 120
}

struct MapKitEarthView: UIViewRepresentable {
    let places: [TravelPlace]
    var horizontalPresentationOffset: CGFloat = 0
    let contentRevision: Int
    let camera: GlobeCameraState
    let cameraTransitionRevision: Int
    let isManipulating: Bool
    let showsUserLocation: Bool
    let settleRevision: Int
    var nativeCameraFeedback: NativeGlobeCameraFeedback? = nil
    var photoWallViewportCapture: PhotoWallViewportCapture? = nil
    var preferredPlaceID: String? = nil
    var waitsForInitialRender: Bool = false
    var homeFrameContext: HomeGlobeFrame.Context = .inactive
    var advanceHomeDrift: ((GlobeCameraState, Double) -> GlobeCameraState?)?
    var mapStyle: PhotoMapStyle = .satellite
    var focusedSatelliteCity: GeoCoordinate?
    var cityLanding: GlobeCameraState?
    var scalePresentation: GlobeScalePresentation? = nil
    var onScaleChanged: ((GlobeScale) -> Void)? = nil
    let onViewportSettled: (PhotoViewportSnapshot) -> Void
    let onUserLocationUpdate: (GeoCoordinate) -> Void
    var onViewportInvalidated: (Int) -> Void = { _ in }
    var onInitialRenderReady: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onViewportSettled: onViewportSettled,
            onUserLocationUpdate: onUserLocationUpdate,
            onViewportInvalidated: onViewportInvalidated,
            onInitialRenderReady: onInitialRenderReady
        )
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.overrideUserInterfaceStyle = .dark
        mapView.backgroundColor = .black
        mapView.isUserInteractionEnabled = false
        mapView.showsScale = false
        mapView.showsUserLocation = showsUserLocation
        // Measure MapKit's attribution margins from the full map bounds.
        mapView.insetsLayoutMarginsFromSafeArea = false
        mapView.register(
            TravelMapAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: TravelMapAnnotationView.reuseIdentifier
        )
        updateUIView(mapView, context: context)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.update(
            mapView,
            places: places,
            horizontalPresentationOffset: horizontalPresentationOffset,
            contentRevision: contentRevision,
            camera: camera,
            isManipulating: isManipulating,
            showsUserLocation: showsUserLocation,
            settleRevision: settleRevision,
            nativeCameraFeedback: nativeCameraFeedback,
            photoWallViewportCapture: photoWallViewportCapture,
            preferredPlaceID: preferredPlaceID,
            waitsForInitialRender: waitsForInitialRender,
            homeFrameContext: homeFrameContext,
            advanceHomeDrift: advanceHomeDrift,
            mapStyle: mapStyle,
            focusedSatelliteCity: focusedSatelliteCity,
            cityLanding: cityLanding,
            scalePresentation: scalePresentation,
            onScaleChanged: onScaleChanged,
            onViewportSettled: onViewportSettled,
            onUserLocationUpdate: onUserLocationUpdate,
            onViewportInvalidated: onViewportInvalidated,
            onInitialRenderReady: onInitialRenderReady
        )
    }

    static func dismantleUIView(_ mapView: MKMapView, coordinator: Coordinator) {
        coordinator.cancelPendingSnapshot()
        coordinator.cancelPendingInitialRender()
        coordinator.stopHomeDrift()
        coordinator.styleHandoff.cancel()
        coordinator.styleHandoff.discardFrame()
        coordinator.imageryStatus.finish()
        mapView.showsUserLocation = false
        mapView.delegate = nil
    }

    static func legalLayoutMargins(horizontalPresentationOffset: CGFloat) -> UIEdgeInsets {
        let offset = horizontalPresentationOffset.isFinite ? max(horizontalPresentationOffset, 0) : 0
        // MapKit also uses these margins for the camera's optical center. Keep
        // opposing edges equal: changing an ornament inset on only one side
        // would make a distance-only ring zoom drift across the visible surface.
        var margins = FullScreenMapLayout.margins
        margins.left += offset
        margins.right += offset
        return margins
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        private let signposter = OSSignposter(
            subsystem: "com.doupi.PhotoEarth.PhotoEarth",
            category: "GlobeRendering"
        )
        private var lastContentRevision = -1
        private var lastCamera: GlobeCameraState?
        private var lastMapStyle: PhotoMapStyle?
        private var lastFlatTerrain = false
        fileprivate let homeFrame = HomeGlobeFrame()
        private var driftWork: DispatchWorkItem?
        private var advanceHomeDrift: ((GlobeCameraState, Double) -> GlobeCameraState?)?
        private var lastDriftCamera: GlobeCameraState?

        fileprivate let styleHandoff = MapStyleHandoff()
        fileprivate let imageryStatus = MapImageryStatus()
        private var deliveredScale: GlobeScale?
        private var onScaleChanged: ((GlobeScale) -> Void)?
        private var markerPresentation = GlobeScalePresentation.Markers.places
        private var photoPins: PhotoPinRenderer?
        private var lastSettleRevision = -1
        private var lastDeliveredSettleRevision = -1
        private var isManipulating = false
        private var detailLevel = MapDetailLevel.world
        private var annotationsByID: [String: TravelMapAnnotation] = [:]
        private var placeSpatialIndex = MapPlaceSpatialIndex()
        private var markerViewport: EarthViewport?
        private var viewportWorkItem: DispatchWorkItem?
        private var projectionInvalidationWorkItem: DispatchWorkItem?
        private var initialRenderWorkItem: DispatchWorkItem?
        private var deliveredProjectionIsCurrent: (() -> Bool)?
        private var viewportGeneration = 0
        private var initialRenderGeneration = 0
        private var fullyRenderedCamera: GlobeCameraState?
        private var waitsForInitialRender = false
        private var hasDeliveredInitialRender = false
        private var onViewportSettled: (PhotoViewportSnapshot) -> Void
        private var onUserLocationUpdate: (GeoCoordinate) -> Void
        private var onViewportInvalidated: (Int) -> Void
        private var onInitialRenderReady: () -> Void
        private var lastUserLocation: GeoCoordinate?
        private var nativeCameraFeedback: NativeGlobeCameraFeedback?
        private var preferredPlaceID: String?

        init(
            onViewportSettled: @escaping (PhotoViewportSnapshot) -> Void,
            onUserLocationUpdate: @escaping (GeoCoordinate) -> Void,
            onViewportInvalidated: @escaping (Int) -> Void = { _ in },
            onInitialRenderReady: @escaping () -> Void = {}
        ) {
            self.onViewportSettled = onViewportSettled
            self.onUserLocationUpdate = onUserLocationUpdate
            self.onViewportInvalidated = onViewportInvalidated
            self.onInitialRenderReady = onInitialRenderReady
        }

        func update(
            _ mapView: MKMapView,
            places: [TravelPlace],
            horizontalPresentationOffset: CGFloat,
            contentRevision: Int,
            camera: GlobeCameraState,
            isManipulating: Bool,
            showsUserLocation: Bool,
            settleRevision: Int,
            nativeCameraFeedback: NativeGlobeCameraFeedback? = nil,
            photoWallViewportCapture: PhotoWallViewportCapture? = nil,
            preferredPlaceID: String? = nil,
            waitsForInitialRender: Bool = false,
            homeFrameContext: HomeGlobeFrame.Context = .inactive,
            advanceHomeDrift: ((GlobeCameraState, Double) -> GlobeCameraState?)? = nil,
            mapStyle: PhotoMapStyle = .satellite,
            focusedSatelliteCity: GeoCoordinate? = nil,
            cityLanding: GlobeCameraState? = nil,
            scalePresentation: GlobeScalePresentation? = nil,
            onScaleChanged: ((GlobeScale) -> Void)? = nil,
            onViewportSettled: @escaping (PhotoViewportSnapshot) -> Void,
            onUserLocationUpdate: @escaping (GeoCoordinate) -> Void,
            onViewportInvalidated: @escaping (Int) -> Void = { _ in },
            onInitialRenderReady: @escaping () -> Void = {}
        ) {
            self.onViewportSettled = onViewportSettled
            self.onUserLocationUpdate = onUserLocationUpdate
            self.onViewportInvalidated = onViewportInvalidated
            self.onInitialRenderReady = onInitialRenderReady
            self.nativeCameraFeedback = nativeCameraFeedback
            if lastCamera != camera || lastContentRevision != contentRevision || onScaleChanged == nil
                || photoWallViewportCapture?.isFrozen == true {
                styleHandoff.discardFrame()
            }
            let homeAlreadyRendered = lastMapStyle == .satellite && lastCamera == camera && fullyRenderedCamera == camera
            let returningHome = homeFrame.update(
                in: mapView, context: homeFrameContext, camera: camera,
                canCapture: lastCamera != nil && fullyRenderedCamera == lastCamera && !self.isManipulating,
                isDriftStep: lastDriftCamera == camera
            )
            if case .home = homeFrameContext, let advanceHomeDrift, !isManipulating {
                self.advanceHomeDrift = advanceHomeDrift
            } else {
                stopHomeDrift()
            }
            let beginsObservingScale = self.onScaleChanged == nil && onScaleChanged != nil
            self.onScaleChanged = onScaleChanged
            if onScaleChanged == nil { deliveredScale = nil }
            photoWallViewportCapture?.attach(mapView)
            let wasWaitingForInitialRender = self.waitsForInitialRender
            let beganWaitingForInitialRender = waitsForInitialRender && !wasWaitingForInitialRender
            self.waitsForInitialRender = waitsForInitialRender
            if wasWaitingForInitialRender && !waitsForInitialRender {
                cancelPendingInitialRender()
            }
            let margins = MapKitEarthView.legalLayoutMargins(
                horizontalPresentationOffset: horizontalPresentationOffset
            )
            if mapView.layoutMargins != margins {
                // The map keeps fixed bounds while the parent translates it.
                // Compensate only the public ornament margins, not the camera.
                mapView.layoutMargins = margins
                cancelPendingSnapshot()
            }
            let flatTerrain = scalePresentation?.scale == .map && mapStyle == .standard
            let targetStyle = MapStyleHandoff.Style(map: mapStyle, flat: flatTerrain)
            if photoWallViewportCapture?.isFrozen != true, lastMapStyle == .satellite, mapStyle == .satellite,
               nativeCameraFeedback?.renderedSatelliteCamera != nil,
               let landing = cityLanding ?? (onScaleChanged != nil && styleHandoff.cityTarget == camera ? camera : nil) {
                styleHandoff.warmCity(landing, from: camera, in: mapView)
            } else if photoWallViewportCapture?.isFrozen != true, lastMapStyle == .satellite,
                      mapStyle == .satellite, nativeCameraFeedback?.renderedSatelliteCamera != nil,
                      let focusedSatelliteCity, mapView.window != nil {
                let landing = GlobeCameraState(center: focusedSatelliteCity, distance: GlobeCameraState.regionalDistance)
                styleHandoff.warmSatellite(to: landing.mapConstrained(), from: camera, in: mapView)
            } else if photoWallViewportCapture?.isFrozen == true || (lastMapStyle == mapStyle && flatTerrain == lastFlatTerrain) {
                if styleHandoff.isPreparing { imageryStatus.finish() }
                styleHandoff.cancel()
            } else if lastMapStyle != nil, mapView.window != nil, onScaleChanged != nil {
                imageryStatus.start(in: mapView)
                styleHandoff.prepare(targetStyle, at: camera, in: mapView) { [weak self, weak mapView, weak photoWallViewportCapture] in
                    guard let self, let mapView, photoWallViewportCapture?.isFrozen != true else { return }
                    self.install(targetStyle, on: mapView)
                    self.scheduleViewportSnapshot(from: mapView)
                }
            } else {
                styleHandoff.cancel()
                install(targetStyle, on: mapView, preservingCamera: lastCamera == camera)
            }
            let nextDetailLevel = detailLevel.updated(for: camera.distance)
            let preferredPlaceChanged = self.preferredPlaceID != preferredPlaceID
            self.preferredPlaceID = preferredPlaceID
            let appearanceChanged = preferredPlaceChanged || self.isManipulating != isManipulating
                || nextDetailLevel != detailLevel
            if isManipulating && !self.isManipulating {
                // A new contact invalidates the last projection even before
                // its first camera frame has changed any coordinates.
                cancelPendingSnapshot()
                deliveredProjectionIsCurrent = nil
                fullyRenderedCamera = nil
                if !hasDeliveredInitialRender { cancelPendingInitialRender() }
            }
            self.isManipulating = isManipulating
            detailLevel = nextDetailLevel

            let contentChanged = lastContentRevision != contentRevision
            if contentChanged {
                lastContentRevision = contentRevision
                placeSpatialIndex = MapPlaceSpatialIndex(places: places)
            }
            if contentChanged || preferredPlaceChanged {
                // Preserve the last settled regional budget. Metadata can be
                // published while the camera is stationary, with no new settle
                // revision to repair a temporary global allocation afterward.
                updateMapContent(mapView, viewport: markerViewport)
            }
            if mapView.showsUserLocation != showsUserLocation {
                mapView.showsUserLocation = showsUserLocation
            }

            if photoWallViewportCapture?.isFrozen == true {
                // A pending render from before Select must not change the
                // map underneath the wall or invalidate its selection.
                lastCamera = camera
                recordNativeCamera(from: mapView)
            } else if lastCamera != camera {
                lastCamera = camera
                cancelPendingSnapshot()
                fullyRenderedCamera = nil
                if !hasDeliveredInitialRender { cancelPendingInitialRender() }
                deliveredProjectionIsCurrent = nil
                let interval = signposter.isEnabled ? signposter.beginInterval("GlobeCameraApply") : nil
                let admissible = nativeCameraFeedback?.constrained(camera) ?? camera.mapConstrained()
                let mapCamera = admissible.nativeCamera
                // The experience model owns the only 30 fps display link, including
                // flights. An additional MapKit animation would trail that state
                // and could freeze the photo wall on a different part of the world.
                mapView.setCamera(mapCamera, animated: false)
                recordNativeCamera(from: mapView)
                if let interval { signposter.endInterval("GlobeCameraApply", interval) }
            }

            if beginsObservingScale { recordNativeCamera(from: mapView) }
            if let markers = scalePresentation?.markers, markerPresentation != markers {
                let hadPhotoPins = showsPhotoPins
                markerPresentation = markers
                if showsPhotoPins || markers == .places, showsPhotoPins != hadPhotoPins {
                    dissolveContents(of: mapView)
                }
                switch markers {
                case let .photos(_, clusters):
                    if photoPins == nil { photoPins = PhotoPinRenderer(map: mapView) }
                    if let photoPins {
                        let anchors = photoPins.pinAnchors(clusters)
                        photoPins.displayPins(anchors, isActive: true)
                    }
                case .places, .awaitingPhotos:
                    photoPins?.displayPins([], isActive: false)
                }
                updateMapContent(mapView, viewport: markerViewport)
            }
            if appearanceChanged { updateAppearance(in: mapView) }

            if returningHome && !homeAlreadyRendered {
                homeFrame.show(in: mapView)
                if homeFrame.isShowing {
                    mapView.layer.removeAnimation(forKey: "globe-scale-handoff")
                    imageryStatus.finish()
                }
            }

            scheduleHomeDrift(in: mapView)
            if beganWaitingForInitialRender, fullyRenderedCamera == lastCamera {
                scheduleInitialRenderReady(from: mapView)
            }

            if lastSettleRevision != settleRevision {
                lastSettleRevision = settleRevision
                deliveredProjectionIsCurrent = nil
                scheduleViewportSnapshot(from: mapView)
            }
            invalidateDeliveredProjectionIfNeeded()
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if annotation is MapReviewPhotoAnnotation { return photoPins?.view(for: annotation) }
            guard let annotation = annotation as? TravelMapAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: TravelMapAnnotationView.reuseIdentifier,
                for: annotation
            ) as? TravelMapAnnotationView
            view?.configure(isMoving: isManipulating, detailLevel: detailLevel, isHighlighted: annotation.placeID == preferredPlaceID)
            return view
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard let location = userLocation.location,
                  location.horizontalAccuracy >= 0 else { return }
            let coordinate = GeoCoordinate(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
            guard coordinate.isValid, coordinate != lastUserLocation else { return }
            lastUserLocation = coordinate
            onUserLocationUpdate(coordinate)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            recordNativeCamera(from: mapView)
            if invalidateDeliveredProjectionIfNeeded() { return }
            // A map layout may finish after SwiftUI applied its state. Coalesce
            // region callbacks and only publish a requested, stationary viewport.
            guard !isManipulating,
                  lastDeliveredSettleRevision != lastSettleRevision else { return }
            scheduleViewportSnapshot(from: mapView)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            recordNativeCamera(from: mapView)
            invalidateDeliveredProjectionIfNeeded()
        }

        private func recordNativeCamera(from mapView: MKMapView) {
            guard let lastCamera, mapView.bounds.width > 1, mapView.bounds.height > 1 else { return }
            let native = mapView.camera
            let center = GeoCoordinate(latitude: native.centerCoordinate.latitude,
                                       longitude: native.centerCoordinate.longitude)
            guard center.isValid, native.centerCoordinateDistance.isFinite,
                  native.centerCoordinateDistance > 0 else { return }
            let scale = GlobeScale(distance: native.centerCoordinateDistance, requestedDistance: lastCamera.distance)
            if deliveredScale != scale, onScaleChanged != nil {
                deliveredScale = scale
                // setCamera can call its delegate synchronously during a SwiftUI update.
                DispatchQueue.main.async { [weak self] in
                    guard self?.deliveredScale == scale else { return }
                    self?.onScaleChanged?(scale)
                }
            }
            nativeCameraFeedback?.record(requested: lastCamera, actual: GlobeCameraState(
                center: center, distance: native.centerCoordinateDistance
            ))
        }

        func mapViewWillStartLoadingMap(_ mapView: MKMapView) {
            if !homeFrame.isShowing { imageryStatus.start(in: mapView) }
        }

        func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
            if fullyRendered, !styleHandoff.isWaitingToInstall { imageryStatus.finish() }
            if !fullyRendered {
                fullyRenderedCamera = nil
                if !hasDeliveredInitialRender { cancelPendingInitialRender() }
            } else {
                if lastMapStyle == .satellite { nativeCameraFeedback?.renderedSatelliteCamera = lastCamera }
                styleHandoff.revealMap()
                homeFrame.didRender(camera: lastCamera)
                fullyRenderedCamera = lastCamera
                scheduleHomeDrift(in: mapView)
                scheduleInitialRenderReady(from: mapView)
            }
            if fullyRendered, invalidateDeliveredProjectionIfNeeded() { return }
            // Initial projection can be unavailable before MapKit finishes its
            // first layout/render. Retry the outstanding request on this real
            // readiness signal after the short timer budget has been exhausted.
            guard fullyRendered, viewportWorkItem == nil, !isManipulating,
                  lastDeliveredSettleRevision != lastSettleRevision else { return }
            scheduleViewportSnapshot(from: mapView)
        }

        fileprivate func stopHomeDrift() {
            driftWork?.cancel()
            driftWork = nil
            advanceHomeDrift = nil
            lastDriftCamera = nil
        }

        private func canDrift(from camera: GlobeCameraState) -> Bool {
            fullyRenderedCamera == camera || lastDriftCamera == camera
        }

        private func scheduleHomeDrift(in map: MKMapView) {
            guard map.window != nil, advanceHomeDrift != nil, driftWork == nil, !homeFrame.isShowing,
                  let camera = lastCamera, canDrift(from: camera) else { return }
            // A subpixel step often reuses the same tiles without another render
            // callback. Continue that arc until a different camera takes over.
            let interval = 0.125
            let work = DispatchWorkItem { [weak self, weak map] in
                guard let self else { return }
                driftWork = nil
                guard map?.window != nil, lastCamera == camera, canDrift(from: camera),
                      !homeFrame.isShowing, let advanceHomeDrift else {
                    if let map { scheduleHomeDrift(in: map) }
                    return
                }
                lastDriftCamera = advanceHomeDrift(camera, interval)
            }
            driftWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
        }

        private func install(_ style: MapStyleHandoff.Style, on mapView: MKMapView, preservingCamera: Bool = true) {
            let currentCamera = preservingCamera ? mapView.camera.copy() as? MKMapCamera : nil
            cancelPendingSnapshot()
            deliveredProjectionIsCurrent = nil
            fullyRenderedCamera = nil
            cancelPendingInitialRender()
            if lastMapStyle == .satellite, style.map == .standard,
               lastCamera?.distance == GlobeCameraState.regionalDistance {
                styleHandoff.holdSatelliteFrame(in: mapView)
            } else {
                styleHandoff.discardFrame()
                if lastMapStyle != nil { dissolveContents(of: mapView) }
            }
            lastMapStyle = style.map
            nativeCameraFeedback?.renderedSatelliteCamera = nil
            mapView.accessibilityIdentifier = style.map == .standard ? "earth-native-streets" : "earth-native-satellite"
            lastFlatTerrain = style.flat
            mapView.preferredConfiguration = style.map.configuration(realisticTerrain: !style.flat)
            if let currentCamera {
                mapView.setCamera(currentCamera, animated: false)
                recordNativeCamera(from: mapView)
            }
            if lastSettleRevision >= 0, lastDeliveredSettleRevision == lastSettleRevision {
                let revision = lastSettleRevision
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.lastSettleRevision == revision else { return }
                    self.onViewportInvalidated(revision)
                }
            }
        }

        private func dissolveContents(of mapView: MKMapView) {
            guard mapView.window != nil, !UIAccessibility.isReduceMotionEnabled else { return }
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.2
            mapView.layer.add(transition, forKey: "globe-scale-handoff")
        }

        private var showsPhotoPins: Bool {
            if case .photos = markerPresentation { return true }
            return false
        }

        private func updateMapContent(
            _ mapView: MKMapView,
            viewport: EarthViewport? = nil
        ) {
            let interval = signposter.isEnabled ? signposter.beginInterval("GlobeMapContent") : nil
            defer {
                if let interval { signposter.endInterval("GlobeMapContent", interval) }
            }
            // Only an index revision or a meaningfully changed settled view
            // chooses markers. Camera frames never sort all place summaries.
            let representatives = showsPhotoPins ? [] : placeSpatialIndex.representatives(in: viewport, preferredPlaceID: preferredPlaceID)
            let retainedIDs = Set(representatives.map(\.id))
            let removed = annotationsByID.values.filter { !retainedIDs.contains($0.placeID) }
            for annotation in removed { annotationsByID.removeValue(forKey: annotation.placeID) }
            mapView.removeAnnotations(removed)

            var inserted: [TravelMapAnnotation] = []
            for place in representatives {
                if let existing = annotationsByID[place.id] {
                    if existing.location == place.coordinate {
                        continue
                    }
                    mapView.removeAnnotation(existing)
                }
                let annotation = TravelMapAnnotation(place: place)
                annotationsByID[place.id] = annotation
                inserted.append(annotation)
            }
            mapView.addAnnotations(inserted)
        }

        private func updateAppearance(in mapView: MKMapView) {
            for annotation in annotationsByID.values {
                (mapView.view(for: annotation) as? TravelMapAnnotationView)?
                    .configure(isMoving: isManipulating, detailLevel: detailLevel, isHighlighted: annotation.placeID == preferredPlaceID)
            }
        }

        func cancelPendingSnapshot() {
            viewportGeneration &+= 1
            viewportWorkItem?.cancel()
            viewportWorkItem = nil
            projectionInvalidationWorkItem?.cancel()
            projectionInvalidationWorkItem = nil
        }

        func cancelPendingInitialRender() {
            initialRenderGeneration &+= 1
            initialRenderWorkItem?.cancel()
            initialRenderWorkItem = nil
        }

        private func scheduleInitialRenderReady(from mapView: MKMapView) {
            guard waitsForInitialRender, !hasDeliveredInitialRender, !isManipulating,
                  fullyRenderedCamera == lastCamera,
                  mapView.bounds.width > 1, mapView.bounds.height > 1 else { return }
            cancelPendingInitialRender()
            let generation = initialRenderGeneration
            let renderedCamera = lastCamera
            let work = DispatchWorkItem { [weak self, weak mapView] in
                guard let self, let mapView,
                      self.initialRenderGeneration == generation,
                      self.waitsForInitialRender,
                      !self.hasDeliveredInitialRender,
                      !self.isManipulating,
                      self.lastCamera == renderedCamera,
                      self.fullyRenderedCamera == renderedCamera,
                      mapView.bounds.width > 1, mapView.bounds.height > 1,
                      mapView.window != nil else { return }
                self.initialRenderWorkItem = nil
                self.hasDeliveredInitialRender = true
                self.onInitialRenderReady()
            }
            initialRenderWorkItem = work
            // A quiet interval prevents a transient tile-completion callback
            // from exposing the map while its initial camera is still settling.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.40, execute: work)
        }

        @discardableResult
        private func invalidateDeliveredProjectionIfNeeded() -> Bool {
            guard !isManipulating, let isCurrent = deliveredProjectionIsCurrent,
                  !isCurrent() else { return false }
            // Native layout/normalization may change a ready image strip after
            // its query has finished. Consume the old identity once, so repeated
            // region/render callbacks cannot restart the stationary debounce.
            deliveredProjectionIsCurrent = nil
            cancelPendingSnapshot()
            let generation = viewportGeneration
            let revision = lastSettleRevision
            let requestedCamera = lastCamera
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.viewportGeneration == generation,
                      self.lastSettleRevision == revision,
                      self.lastCamera == requestedCamera, !self.isManipulating else { return }
                self.projectionInvalidationWorkItem = nil
                self.onViewportInvalidated(revision)
            }
            projectionInvalidationWorkItem = work
            // Delegate callbacks may occur inside updateUIView / setCamera.
            // Publish model invalidation only after that SwiftUI update returns.
            DispatchQueue.main.async(execute: work)
            return true
        }

        private func scheduleViewportSnapshot(from mapView: MKMapView, attempt: Int = 0) {
            cancelPendingSnapshot()
            guard !isManipulating,
                  lastDeliveredSettleRevision != lastSettleRevision else { return }
            let generation = viewportGeneration
            let revision = lastSettleRevision
            let requestedCamera = lastCamera
            let work = DispatchWorkItem { [weak self, weak mapView] in
                guard let self, let mapView,
                      self.viewportGeneration == generation,
                      self.lastSettleRevision == revision,
                      self.lastCamera == requestedCamera,
                      !self.isManipulating else { return }
                self.viewportWorkItem = nil
                guard mapView.bounds.width > 1, mapView.bounds.height > 1 else {
                    // A disappearing or not-yet-laid-out view must not leave an
                    // unbounded timer chain behind it.
                    if attempt < 8 {
                        self.scheduleViewportSnapshot(from: mapView, attempt: attempt + 1)
                    }
                    return
                }
                guard let snapshot = self.photoSnapshot(in: mapView, isCurrent: { [weak self] in
                    guard let self else { return false }
                    return self.viewportGeneration == generation
                        && self.lastSettleRevision == revision
                        && self.lastCamera == requestedCamera
                        && !self.isManipulating
                }) else {
                    if attempt < 8 {
                        self.scheduleViewportSnapshot(from: mapView, attempt: attempt + 1)
                    }
                    return
                }
                if MapPlaceSpatialIndex.needsRefresh(from: self.markerViewport, to: snapshot.viewport) {
                    self.markerViewport = snapshot.viewport
                    self.updateMapContent(mapView, viewport: snapshot.viewport)
                }
                self.lastDeliveredSettleRevision = revision
                self.deliveredProjectionIsCurrent = MapViewportSampler.projectionValidator(in: mapView)
                self.viewportWorkItem = nil
                self.onViewportSettled(snapshot)
            }
            viewportWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: work)
        }

        private func photoSnapshot(
            in mapView: MKMapView, isCurrent: @escaping () -> Bool
        ) -> PhotoViewportSnapshot? {
            let interval = signposter.isEnabled ? signposter.beginInterval("GlobeViewportSnapshot") : nil
            defer {
                if let interval { signposter.endInterval("GlobeViewportSnapshot", interval) }
            }
            return MapViewportSampler.photoSnapshot(in: mapView, isCurrent: isCurrent)
        }
    }
}

@MainActor
enum MapViewportSampler {
    /// Tracks native projection independently of an app query generation. This
    /// remains useful after a delivered snapshot's asynchronous query is done.
    static func projectionValidator(in mapView: MKMapView) -> () -> Bool {
        let projection = ProjectionState(in: mapView)
        return { [weak mapView] in
            guard let mapView else { return false }
            return ProjectionState(in: mapView) == projection
        }
    }

    /// Captures public MapKit projection state without retaining the map or its
    /// coordinator. Native camera normalization is part of this identity too.
    static func photoSnapshot(
        in mapView: MKMapView, isCurrent ownerIsCurrent: @escaping () -> Bool = { true }
    ) -> PhotoViewportSnapshot? {
        guard ownerIsCurrent(), let viewport = viewport(in: mapView) else { return nil }
        let projection = ProjectionState(in: mapView)
        var invalidated = false
        let isCurrent: () -> Bool = { [weak mapView] in
            guard !invalidated, let mapView, ownerIsCurrent(),
                  ProjectionState(in: mapView) == projection else {
                invalidated = true
                return false
            }
            return true
        }
        return PhotoViewportSnapshot(
            viewport: viewport,
            isCurrent: isCurrent,
            containsCoordinate: { [weak mapView] coordinate in
                guard isCurrent(), let mapView, viewport.contains(coordinate) else { return false }
                let point = mapView.convert(coordinate.clLocationCoordinate, toPointTo: mapView)
                guard point.x.isFinite, point.y.isFinite,
                      projection.bounds.contains(point) else { return false }

                // A back-side coordinate can have a finite projection inside
                // the rectangle. It must also round-trip to the same surface
                // location, within half a projection point's angular scale.
                let location = mapView.convert(point, toCoordinateFrom: mapView)
                let roundTrip = GeoCoordinate(latitude: location.latitude, longitude: location.longitude)
                let angularTolerance = max(
                    0.00001,
                    viewport.angularRadius / Double(hypot(projection.bounds.width, projection.bounds.height)) * 0.5
                )
                return roundTrip.isValid && GlobeMath.angularDistanceDegrees(
                    from: coordinate, to: roundTrip
                ) <= angularTolerance
            }
        )
    }

    private nonisolated struct ProjectionState: Equatable {
        let center: GeoCoordinate
        let distance: Double
        let altitude: Double
        let pitch: Double
        let heading: Double
        let bounds: CGRect
        let margins: UIEdgeInsets
        let windowIdentity: ObjectIdentifier?
        let isStandardMap: Bool

        @MainActor init(in mapView: MKMapView) {
            let camera = mapView.camera
            center = GeoCoordinate(
                latitude: camera.centerCoordinate.latitude, longitude: camera.centerCoordinate.longitude
            )
            distance = camera.centerCoordinateDistance
            altitude = camera.altitude
            pitch = camera.pitch
            heading = camera.heading
            bounds = mapView.bounds
            margins = mapView.layoutMargins
            windowIdentity = mapView.window.map { ObjectIdentifier($0) }
            isStandardMap = mapView.preferredConfiguration is MKStandardMapConfiguration
        }
    }

    static func viewport(in mapView: MKMapView) -> EarthViewport? {
        let bounds = mapView.bounds.insetBy(dx: 1, dy: 1)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let screenCenter = CGPoint(x: mapView.bounds.midX, y: mapView.bounds.midY)
        let centerLocation = mapView.convert(screenCenter, toCoordinateFrom: mapView)
        let center = GeoCoordinate(latitude: centerLocation.latitude, longitude: centerLocation.longitude)
        guard center.isValid else { return nil }

        // Standard maps can use a planar presentation even with realistic
        // terrain. Native projection and round-trip checks own visibility;
        // applying the satellite sphere's cap would omit visible map photos.
        let isStandardMap = mapView.preferredConfiguration is MKStandardMapConfiguration
        let horizon = isStandardMap ? 180 : MapEarthGeometry.surfaceVisibilityRadius(
            distance: mapView.camera.centerCoordinateDistance, pitch: mapView.camera.pitch
        )
        let points = [
            CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.midX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.midY),
            CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.midX, y: bounds.maxY),
            CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.midY),
        ]
        var angles: [Double] = []
        angles.reserveCapacity(points.count)

        func sample(_ point: CGPoint) -> Double? {
            let location = mapView.convert(point, toCoordinateFrom: mapView)
            let coordinate = GeoCoordinate(latitude: location.latitude, longitude: location.longitude)
            guard coordinate.isValid else { return nil }
            let angle = GlobeMath.angularDistanceDegrees(from: center, to: coordinate)
            guard angle.isFinite, angle <= horizon * 1.001 else { return nil }
            // Some globe projections clamp a point in space onto the limb rather
            // than returning an invalid coordinate. Round-trip it to distinguish
            // a real surface sample from that clamped result.
            let projected = mapView.convert(location, toPointTo: mapView)
            guard projected.x.isFinite, projected.y.isFinite,
                  hypot(projected.x - point.x, projected.y - point.y) <= 4 else { return nil }
            return angle
        }

        for point in points {
            if let angle = sample(point) {
                angles.append(angle)
                continue
            }

            // A failed edge projection is not permission to load a hemisphere.
            // Trace this one ray back toward the valid center. This fixed-cost
            // branch normally runs only when the planet's limb is on screen;
            // city views use just eight direct perimeter samples.
            var inside = 0.0
            var outside = 1.0
            var lastAngle = 0.0
            for _ in 0..<12 {
                let fraction = (inside + outside) * 0.5
                let candidate = CGPoint(
                    x: screenCenter.x + (point.x - screenCenter.x) * fraction,
                    y: screenCenter.y + (point.y - screenCenter.y) * fraction
                )
                if let angle = sample(candidate) {
                    inside = fraction
                    lastAngle = angle
                } else {
                    outside = fraction
                }
            }
            if lastAngle >= horizon * 0.95 {
                angles.append(horizon)
                break
            }
            if lastAngle > 0 { angles.append(lastAngle) }
        }

        guard let radius = MapEarthGeometry.viewportRadius(
            sampledAngles: angles,
            horizonAngle: horizon,
            viewportDiagonal: hypot(bounds.width, bounds.height)
        ) else { return nil }
        let nativeCamera = mapView.camera
        let visibility = EarthSurfaceVisibility(
            center: GeoCoordinate(
                latitude: nativeCamera.centerCoordinate.latitude,
                longitude: nativeCamera.centerCoordinate.longitude
            ),
            distance: nativeCamera.centerCoordinateDistance,
            pitch: nativeCamera.pitch,
            heading: nativeCamera.heading
        )
        return EarthViewport(center: center, angularRadius: radius, visibilityCap: isStandardMap ? nil : visibility)
    }
}

nonisolated enum MapPlaceLOD {
    private struct Cell: Hashable {
        let latitude: Int
        let longitude: Int
    }

    static func representatives(from places: [TravelPlace], limit: Int, preferredPlaceID: String? = nil) -> [TravelPlace] {
        guard limit > 0 else { return [] }
        let sorted = places.filter { $0.coordinate.isValid }.sorted {
            if ($0.id == preferredPlaceID) != ($1.id == preferredPlaceID) { return $0.id == preferredPlaceID }
            if $0.endDate == $1.endDate { return $0.id < $1.id }
            return $0.endDate > $1.endDate
        }
        var countByCell: [Cell: Int] = [:]
        var selectedIDs = Set<String>()
        selectedIDs.reserveCapacity(min(limit, places.count))
        var selected: [TravelPlace] = []
        selected.reserveCapacity(min(limit, places.count))

        for place in sorted {
            // +180 and -180 represent the same meridian and belong to one cell.
            let longitude = place.coordinate.longitude == 180 ? -180 : place.coordinate.longitude
            let cell = Cell(
                latitude: min(Int(floor((place.coordinate.latitude + 90) / 2)), 89),
                longitude: Int(floor((longitude + 180) / 2))
            )
            guard !selectedIDs.contains(place.id), countByCell[cell, default: 0] < 2 else { continue }
            countByCell[cell, default: 0] += 1
            selectedIDs.insert(place.id)
            selected.append(place)
            if selectedIDs.count == limit { break }
        }

        return selected
    }
}

nonisolated enum MapEarthGeometry {
    /// Conservative spherical cap for a tilted camera. A tilted view's look-at
    /// coordinate differs from the point directly below the camera; using only
    /// an overhead horizon can reject visible ground at the bottom of the frame.
    static func surfaceVisibilityRadius(distance: Double, pitch: Double) -> Double {
        guard distance.isFinite, distance > 0, pitch.isFinite else { return 2 }
        let tilt = min(max(pitch, 0), 85) * .pi / 180
        guard tilt > 0 else { return horizonAngle(distance: distance) }
        let radius = 6_371_000.0
        let axialDistance = radius + distance * cos(tilt)
        let lateralDistance = distance * sin(tilt)
        let cameraRadius = hypot(axialDistance, lateralDistance)
        let limbAngle = acos(min(radius / cameraRadius, 1))
        let centerOffset = atan2(lateralDistance, axialDistance)
        return min(94, max(horizonAngle(distance: distance), (limbAngle + centerOffset) * 180 / .pi))
    }

    static func horizonAngle(distance: Double) -> Double {
        let earthRadius = 6_371_000.0
        guard distance.isFinite, distance > 0 else { return 2 }
        return acos(earthRadius / (earthRadius + distance)) * 180 / .pi
    }

    static func viewportRadius(
        sampledAngles: [Double],
        horizonAngle: Double,
        viewportDiagonal: Double
    ) -> Double? {
        guard horizonAngle.isFinite, horizonAngle > 0,
              viewportDiagonal.isFinite, viewportDiagonal > 0,
              let largest = sampledAngles.filter({ $0.isFinite && $0 > 0 }).max() else { return nil }
        // Two screen points of tolerance, at every scale. A fixed angular pad
        // would turn a street-sized viewport into a many-kilometre photo query.
        let paddingScale = 1 + 4 / viewportDiagonal
        return min(largest * paddingScale, horizonAngle)
    }
}

private enum MapDetailLevel {
    case world
    case regional

    func updated(for distance: Double) -> Self {
        // Hysteresis prevents ring input close to a threshold from repeatedly
        // rebuilding annotation appearance.
        switch self {
        case .world: distance < 7_500_000 ? .regional : .world
        case .regional: distance > 9_000_000 ? .world : .regional
        }
    }
}

private final class TravelMapAnnotation: NSObject, MKAnnotation {
    let placeID: String
    let location: GeoCoordinate
    let coordinate: CLLocationCoordinate2D

    init(place: TravelPlace) {
        placeID = place.id
        location = place.coordinate
        coordinate = place.coordinate.clLocationCoordinate
    }
}

final class TravelMapAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "travel-place"
    static let worldImage = makeMarker(diameter: 44)
    private static let regionalImage = makeMarker(diameter: 56)
    static let photoImage = makeMarker(diameter: 64, emphasizesPhoto: true)
    private var detailLevel: MapDetailLevel?
    private var emphasizesPhoto = false

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    fileprivate func configure(isMoving: Bool, detailLevel: MapDetailLevel, isHighlighted: Bool = false) {
        if self.detailLevel != detailLevel || emphasizesPhoto != isHighlighted {
            self.detailLevel = detailLevel
            emphasizesPhoto = isHighlighted
            image = isHighlighted ? Self.photoImage : (detailLevel == .world ? Self.worldImage : Self.regionalImage)
        }
        alpha = isMoving && !isHighlighted ? 0.54 : 1
        displayPriority = isHighlighted ? .required : .defaultHigh
    }

    private func configureView() {
        backgroundColor = .clear
        isOpaque = false
        canShowCallout = false
        collisionMode = .circle
        displayPriority = .defaultHigh
        isAccessibilityElement = false
    }

    private static func makeMarker(diameter: CGFloat, emphasizesPhoto: Bool = false) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let size = CGSize(width: diameter, height: diameter)
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            let center = CGPoint(x: diameter / 2, y: diameter / 2)
            // A small blue-white light dissolves into the surface. The gradient
            // has no stroked ring or hard disk, and is rasterized just once per
            // detail level rather than blurred in a separate layer every frame.
            let colors = [
                UIColor(red: 0.94, green: 0.99, blue: 1, alpha: 0.98).cgColor,
                UIColor(red: 0.80, green: 0.95, blue: 1, alpha: 0.86).cgColor,
                UIColor(red: 0.61, green: 0.84, blue: 0.94, alpha: 0.48).cgColor,
                UIColor(red: 0.53, green: 0.77, blue: 0.88, alpha: 0.19).cgColor,
                UIColor(red: 0.47, green: 0.71, blue: 0.83, alpha: 0.05).cgColor,
                UIColor(red: 0.47, green: 0.71, blue: 0.83, alpha: 0).cgColor
            ]
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors as CFArray,
                locations: emphasizesPhoto ? [0, 0.14, 0.26, 0.46, 0.72, 1] : [0, 0.065, 0.16, 0.34, 0.65, 1]
            ) {
                context.drawRadialGradient(
                    gradient, startCenter: center, startRadius: 0,
                    endCenter: center, endRadius: diameter / 2, options: []
                )
            }
        }
    }
}

private extension GeoCoordinate {
    var clLocationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension GlobeCameraState {
    @MainActor var nativeCamera: MKMapCamera {
        MKMapCamera(lookingAtCenter: center.clLocationCoordinate, fromDistance: distance,
                    pitch: presentationPitch, heading: 0)
    }
}
