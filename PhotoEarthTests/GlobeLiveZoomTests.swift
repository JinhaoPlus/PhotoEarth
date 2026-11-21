import Combine
import QuartzCore
import SwiftUI
import Testing
@testable import PhotoEarth

struct GlobeLiveZoomTests {
    @Test(arguments: [false, true]) @MainActor
    func dockKeepsDragLiveButButtonsCannotNavigateTheGlobe(reduceMotion: Bool) {
        let model = makeModel()
        defer { model.deactivate() }
        var actions: [RemoteSelectGestureRecognizer.Action] = []
        model.activate(initialCenter: nil, onSelectAction: { actions.append($0) }) { _, _ in [] }
        model.setZoomControlsPresented(true)
        #expect(model.acceptsTouchPan)
        #expect(!model.acceptsUIKitSelectPresses)
        let origin = model.camera
        let now = CACurrentMediaTime()
        model.receiveSelectPress(true, source: .hardware, at: now)
        model.receiveSelectPress(false, source: .hardware, at: now + 0.1)
        model.setDirectionalInput(horizontal: 1, vertical: 0)
        model.setDirectionalInput(horizontal: 0, vertical: 0)
        model.nudge(.right, at: now + 1)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: reduceMotion)
        #expect(actions.isEmpty)
        #expect(model.camera == origin)

        var publications = 0
        let token = model.$camera.dropFirst().sink { _ in publications += 1 }
        defer { token.cancel() }
        model.receiveTouchContact(true)
        model.applyTouchPan(horizontalDelta: 0.06, verticalDelta: 0)
        model.applyTouchPan(horizontalDelta: 0.06, verticalDelta: 0)
        #expect(publications == 0)
        model.receiveTouchContact(false)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: reduceMotion)
        #expect(model.camera.center.longitude < origin.center.longitude)
        #expect(model.camera.distance == origin.distance)
        #expect(publications == 1)
        let stopped = model.camera
        for _ in 0..<20 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: reduceMotion) }
        #expect(model.camera == stopped)
        #expect(!model.isManipulating)
    }

    @Test(arguments: [false, true]) @MainActor
    func dragThenZoomThenDragUsesTheVisibleCameraWhileDockStaysOpen(reduceMotion: Bool) {
        let model = makeModel()
        defer { model.deactivate() }
        model.setZoomControlsPresented(true)
        model.receiveTouchContact(true)
        model.applyTouchPan(horizontalDelta: 0.2, verticalDelta: -0.08)
        model.receiveTouchContact(false)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: reduceMotion)
        let dragged = model.camera
        model.zoomIn()
        model.advanceMotionFrame(elapsed: 0.12, reduceMotion: reduceMotion)
        let visibleZoom = model.camera
        #expect(visibleZoom.center == dragged.center)
        #expect(visibleZoom.distance < dragged.distance)
        // A new real drag directly takes over the currently visible zoom frame.
        model.receiveTouchContact(true)
        model.applyTouchPan(horizontalDelta: -0.1, verticalDelta: 0)
        model.receiveTouchContact(false)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: reduceMotion)
        #expect(model.camera.distance == visibleZoom.distance)
        #expect(model.camera.center.longitude > visibleZoom.center.longitude)
        let stopped = model.camera
        for _ in 0..<20 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: reduceMotion) }
        #expect(model.camera == stopped, "Interrupted zoom must not pull the dragged camera back")
        #expect(!model.acceptsUIKitSelectPresses, "The dock remains the button owner")
        model.zoomOut()
        model.advanceMotionFrame(elapsed: 1, reduceMotion: reduceMotion)
        #expect(model.camera.center == stopped.center)
        #expect(model.camera.distance > stopped.distance)
    }

    @Test @MainActor
    func dockButtonConsumesQueuedPanAndKeepsOldContactLocked() {
        let model = makeModel()
        defer { model.deactivate() }
        model.setZoomControlsPresented(true)
        let original = model.camera
        model.receiveTouchContact(true)
        model.applyTouchPan(horizontalDelta: 0.2, verticalDelta: 0)
        model.claimTouchForPhysicalPress()
        model.zoomIn()
        model.applyTouchPan(horizontalDelta: 0.2, verticalDelta: 0)
        model.advanceMotionFrame(elapsed: 1, reduceMotion: false)
        #expect(model.camera.center == original.center)
        #expect(model.camera.distance < original.distance)
        let zoomed = model.camera
        model.applyTouchPan(horizontalDelta: 0.2, verticalDelta: 0)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        #expect(model.camera == zoomed)
        model.receiveTouchContact(false)
        model.receiveTouchContact(true)
        model.applyTouchPan(horizontalDelta: 0.1, verticalDelta: 0)
        model.receiveTouchContact(false)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        #expect(model.camera.center != zoomed.center)
    }

    @Test @MainActor
    func closingDockDoesNotInterruptAnOngoingDragAndRestoresShortPress() {
        let model = makeModel()
        defer { model.deactivate() }
        var actions: [RemoteSelectGestureRecognizer.Action] = []
        model.activate(initialCenter: nil, onSelectAction: { actions.append($0) }) { _, _ in [] }
        model.setZoomControlsPresented(true)
        let original = model.camera
        model.receiveTouchContact(true)
        model.applyTouchPan(horizontalDelta: 0.1, verticalDelta: 0)
        model.setZoomControlsPresented(false)
        model.applyTouchPan(horizontalDelta: 0.1, verticalDelta: 0)
        model.receiveTouchContact(false)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        var expected = original
        expected.panWithTouchSurface(horizontalDelta: 0.2, verticalDelta: 0,
                                     sensitivity: 84 * original.navigationScale)
        #expect(model.camera == expected)
        #expect(model.acceptsUIKitSelectPresses)
        let now = CACurrentMediaTime()
        model.receiveSelectPress(true, source: .uiKit, at: now)
        model.receiveSelectPress(false, source: .uiKit, at: now + 0.1)
        #expect(actions == [.singlePress])
    }

    @Test @MainActor
    func systemInterruptionPreservesDockRoutingButNeverReplaysDrag() {
        let model = makeModel()
        defer { model.deactivate() }
        model.setZoomControlsPresented(true)
        model.receiveTouchContact(true)
        model.applyTouchPan(horizontalDelta: 0.2, verticalDelta: 0)
        let original = model.camera
        model.setSceneActive(false)
        #expect(!model.acceptsTouchPan)
        model.applyTouchPan(horizontalDelta: 0.4, verticalDelta: 0)
        model.setSceneActive(true)
        #expect(model.acceptsTouchPan)
        #expect(!model.acceptsUIKitSelectPresses)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        #expect(model.camera == original)
        model.pauseDirectManipulation()
        #expect(!model.acceptsTouchPan, "Photo walls still pause every globe input")
        model.applyTouchPan(horizontalDelta: 0.4, verticalDelta: 0)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        #expect(model.camera == original)
    }

    @MainActor private func makeModel() -> GlobeExperienceModel {
        let model = GlobeExperienceModel()
        model.activate(initialCenter: GeoCoordinate(latitude: 0, longitude: 0)) { _, _ in [] }
        model.transitionCamera(to: GeoCoordinate(latitude: 0, longitude: 0), distance: 6_000_000,
                               animated: false, overviewFraming: 0)
        return model
    }
}
