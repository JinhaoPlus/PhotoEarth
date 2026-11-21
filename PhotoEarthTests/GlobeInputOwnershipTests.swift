import Combine
import Foundation
import QuartzCore
import SwiftUI
import Testing
@testable import PhotoEarth

struct GlobeInputOwnershipTests {
    @Test @MainActor
    func restingAndRepeatedLightTouchesPreservePendingAndReadyPhotos() async throws {
        let model = GlobeExperienceModel()
        let center = GeoCoordinate(latitude: 0, longitude: 0)
        var queries = 0
        model.activate(initialCenter: center) { _, _ in
            queries += 1
            return [PhotoAssetRecord(id: "synthetic-light-touch", coordinate: center,
                                    creationDate: Date(timeIntervalSince1970: 1_700_000_000),
                                    pixelWidth: 1_200, pixelHeight: 800, isFavorite: false)]
        }
        defer { model.deactivate() }
        let original = model.camera
        let revision = model.settleRevision
        var publications = 0
        let observation = model.$camera.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        let viewport = EarthViewport(center: center, angularRadius: 30)
        model.receiveViewport(PhotoViewportSnapshot(viewport: viewport, isCurrent: { true },
                                                   containsCoordinate: { viewport.contains($0) }))
        model.receiveTouchContact(true)
        for _ in 0..<80 {
            if model.photoBatchReady { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(model.photoBatchReady, "Resting a thumb must not cancel the pending photo query")
        #expect(model.visiblePhotos.count == 1)
        #expect(queries == 1)
        for _ in 0..<100 {
            model.receiveTouchContact(false)
            model.receiveTouchContact(true)
            model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
            #expect(model.photoBatchReady)
            #expect(!model.isManipulating)
        }
        model.receiveTouchContact(false)
        #expect(model.camera == original)
        #expect(model.settleRevision == revision)
        #expect(publications == 0)
        #expect(queries == 1)
    }

    @Test(arguments: [false, true]) @MainActor
    func releasingDirectionStopsImmediatelyAndOwnsContactUntilLift(reduceMotion: Bool) {
        let model = makeModel()
        defer { model.deactivate() }
        let original = model.camera
        model.receiveTouchContact(true)
        model.setDirectionalInput(horizontal: 1, vertical: 0)
        for _ in 0..<18 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: reduceMotion) }
        let stopped = model.camera
        #expect(stopped != original)
        model.setDirectionalInput(horizontal: 0, vertical: 0)
        for _ in 0..<30 {
            model.applyTouchPan(horizontalDelta: 0.1, verticalDelta: 0.1)
            model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: reduceMotion)
            #expect(model.camera == stopped)
            #expect(!model.isManipulating)
        }
        model.receiveTouchContact(false)
        model.receiveTouchContact(true)
        model.applyTouchPan(horizontalDelta: 0.1, verticalDelta: 0)
        model.receiveTouchContact(false)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: reduceMotion)
        #expect(model.camera != stopped, "A fresh contact may drag immediately after a physical press")
    }

    @Test @MainActor
    func hardwareDirectionsRejectEvenVeryLateFocusDuplicates() {
        let model = makeModel()
        defer { model.deactivate() }
        model.receiveDirectionalAvailability(true)
        model.setDirectionalInput(horizontal: 1, vertical: 0)
        model.setDirectionalInput(horizontal: 0, vertical: 0)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        let stopped = model.camera
        let later = CACurrentMediaTime() + 10
        for direction in [MoveCommandDirection.right, .left, .up, .down] {
            model.nudge(direction, at: later)
            model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
            #expect(model.camera == stopped)
        }
        model.receiveDirectionalAvailability(false)
        model.nudge(.right, at: later)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        #expect(model.camera != stopped, "Simulator and non-Game-Controller directions remain usable")
    }

    @Test @MainActor
    func pausedGlobeRejectsDirectInputWhileExplicitZoomKeepsItsCenter() {
        let model = makeModel()
        defer { model.deactivate() }
        model.receiveTouchContact(true)
        model.applyTouchPan(horizontalDelta: 0.2, verticalDelta: 0)
        model.pauseDirectManipulation()
        let frozen = model.camera
        model.applyTouchPan(horizontalDelta: 0.8, verticalDelta: 0.3)
        model.setDirectionalInput(horizontal: 1, vertical: 0)
        model.nudge(.down)
        model.receiveSelectPress(true, source: .uiKit)
        model.receiveSelectPress(false, source: .uiKit)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        #expect(model.camera == frozen)
        model.zoomIn()
        for _ in 0..<12 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false) }
        #expect(model.camera.center == frozen.center)
        #expect(model.camera.distance < frozen.distance)
        let zoomed = model.camera
        model.resumeDirectManipulation()
        for _ in 0..<12 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false) }
        #expect(model.camera == zoomed, "Resuming must not replay the discarded input")
    }

    @MainActor private func makeModel() -> GlobeExperienceModel {
        let model = GlobeExperienceModel()
        model.activate(initialCenter: GeoCoordinate(latitude: 0, longitude: 0)) { _, _ in [] }
        return model
    }
}
