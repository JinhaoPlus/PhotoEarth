import Combine
import QuartzCore
import SwiftUI
import Testing
@testable import PhotoEarth

struct GlobeSwipeStabilityTests {
    @Test(arguments: [GlobeCameraState.minimumDistance, GlobeCameraState.orbitalDistance]) @MainActor
    func identicalTouchPathIsIndependentOfTheDisplayFrameSchedule(distance: Double) {
        let positions = [(0.2, 0.12), (0.7, 0.16), (0.4, 0.10),
                         (-0.4, 0.1), (-0.7, 0.01), (-0.3, -0.1)]
        var reference: GlobeCameraState?
        for samplesPerFrame in [1, 2, positions.count] {
            let model = makeModel()
            defer { model.deactivate() }
            model.transitionCamera(to: GeoCoordinate(latitude: 25, longitude: 5),
                                   distance: distance, animated: false, overviewFraming: 0)
            var input = RemoteIndirectTouchState()
            input.began(x: 54, y: -54, pointsPerUnit: 540, isPressing: false)
            model.receiveTouchContact(true)
            _ = input.moved(x: 54, y: -54)
            let original = model.camera
            var publications = 0
            let observation = model.$camera.dropFirst().sink { _ in publications += 1 }
            var submittedFrames = 0
            for (index, position) in positions.enumerated() {
                if case let .pan(x, y) = input.moved(x: position.0 * 540, y: -position.1 * 540) {
                    model.applyTouchPan(horizontalDelta: x, verticalDelta: y)
                }
                #expect(publications <= submittedFrames, "Raw callbacks must not publish camera state")
                if (index + 1).isMultiple(of: samplesPerFrame) {
                    model.advanceMotionFrame(elapsed: Double(samplesPerFrame) / 60, reduceMotion: false)
                    submittedFrames += 1
                }
            }
            #expect(model.camera != original, "The path must contain an accepted drag")
            #expect(publications > 0)
            if let reference { #expect(model.camera == reference) }
            else { reference = model.camera }
            model.receiveTouchContact(false)
            let stopped = model.camera
            for _ in 0..<12 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false) }
            #expect(model.camera == stopped)
            #expect(publications <= submittedFrames)
            observation.cancel()
        }
    }

    @Test @MainActor
    func lateUIKitMovementAfterLiftCannotReverseTheCamera() throws {
        let model = makeModel()
        defer { model.deactivate() }
        var input = RemoteIndirectTouchState()
        input.began(x: 54, y: 54, pointsPerUnit: 540, isPressing: false)
        model.receiveTouchContact(true)
        _ = input.moved(x: 54, y: 54)
        let sample = input.moved(x: 108, y: 54)
        guard case let .pan(x, y) = try #require(sample) else {
            Issue.record("The swipe must produce real displacement")
            return
        }
        model.applyTouchPan(horizontalDelta: x, verticalDelta: y)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        let stopped = model.camera
        // The UIKit bridge ends contact without interpreting a terminal touch
        // coordinate as another move. Late callbacks cannot reopen contact.
        input.ended()
        model.receiveTouchContact(false)
        let reset = input.moved(x: 0, y: 0)
        #expect(reset == nil)
        if case let .pan(x, y) = reset {
            model.applyTouchPan(horizontalDelta: x, verticalDelta: y)
        }
        for _ in 0..<30 {
            model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
            #expect(model.camera == stopped)
        }
    }

    @Test(arguments: [false, true]) @MainActor
    func delayedFocusCommandsCannotMoveTheMapAfterAPausedSwipe(reduceMotion: Bool) {
        let model = makeModel()
        defer { model.deactivate() }
        let start = CACurrentMediaTime()
        model.receiveTouchContact(true, at: start)
        model.applyTouchPan(horizontalDelta: 0.2, verticalDelta: 0, at: start + 0.02)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: reduceMotion)
        let stopped = model.camera

        // The thumb pauses on the pad, beyond the old 240 ms movement-only gate.
        model.nudge(.right, at: start + 0.60)
        model.receiveTouchContact(false, at: start + 0.70)
        model.nudge(.right, at: start + 0.71)
        model.nudge(.up, at: start + 0.95)
        for _ in 0..<30 {
            model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: reduceMotion)
            #expect(model.camera == stopped)
        }
    }

    @Test(arguments: [false, true]) @MainActor
    func touchTakesOverAPhysicalTapQueuedBeforeTheDisplayFrame(reduceMotion: Bool) {
        let model = makeModel()
        defer { model.deactivate() }
        let original = model.camera
        // A complete physical tap may leave an impulse pending between frames.
        model.setDirectionalInput(horizontal: 1, vertical: 0)
        model.setDirectionalInput(horizontal: 0, vertical: 0)
        model.receiveTouchContact(true)
        model.applyTouchPan(horizontalDelta: 0.1, verticalDelta: 0)
        model.receiveTouchContact(false)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: reduceMotion)
        var expected = original
        expected.panWithTouchSurface(horizontalDelta: 0.1, verticalDelta: 0,
                                     sensitivity: 84 * original.navigationScale)
        #expect(model.camera == expected)
        for _ in 0..<30 {
            model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: reduceMotion)
            #expect(model.camera == expected)
        }
    }

    @Test(arguments: [false, true]) @MainActor
    func lastRealSwipeSampleIsAppliedOnceEvenIfLiftPrecedesTheFrame(reduceMotion: Bool) {
        let model = makeModel()
        defer { model.deactivate() }
        let original = model.camera
        model.receiveTouchContact(true)
        model.applyTouchPan(horizontalDelta: 0.09, verticalDelta: 0)
        model.applyTouchPan(horizontalDelta: 0.08, verticalDelta: 0)
        model.applyTouchPan(horizontalDelta: 0.08, verticalDelta: 0)
        model.receiveTouchContact(false)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: reduceMotion)
        var expected = original
        expected.panWithTouchSurface(horizontalDelta: 0.25, verticalDelta: 0,
                                     sensitivity: 84 * original.navigationScale)
        #expect(model.camera == expected)
        for _ in 0..<30 {
            model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: reduceMotion)
            #expect(model.camera == expected)
        }
    }

    @Test @MainActor func realPhysicalDirectionStillWorksImmediatelyAfterSwipeRelease() {
        let model = makeModel()
        defer { model.deactivate() }
        model.receiveTouchContact(true)
        model.applyTouchPan(horizontalDelta: 0.1, verticalDelta: 0)
        model.receiveTouchContact(false)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        let stopped = model.camera
        model.setDirectionalInput(horizontal: 1, vertical: 0)
        model.setDirectionalInput(horizontal: 0, vertical: 0)
        for _ in 0..<30 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false) }
        #expect(model.camera.center.longitude > stopped.center.longitude)
    }

    @Test @MainActor func fallbackDirectionRecoversAfterTheReleaseGuard() {
        let model = makeModel()
        model.receiveDirectionalAvailability(false)
        defer { model.deactivate() }
        let start = CACurrentMediaTime()
        model.receiveTouchContact(true, at: start)
        model.applyTouchPan(horizontalDelta: 0.1, verticalDelta: 0, at: start + 0.02)
        model.receiveTouchContact(false, at: start + 0.05)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        let stopped = model.camera
        model.nudge(.right, at: start + 0.50)
        for _ in 0..<30 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false) }
        #expect(model.camera.center.longitude > stopped.center.longitude)
    }

    @Test @MainActor func zoomDoesNotForgetThatTheThumbIsStillOnThePad() {
        let model = makeModel()
        defer { model.deactivate() }
        let start = CACurrentMediaTime()
        model.receiveTouchContact(true, at: start)
        model.zoomIn()
        for _ in 0..<12 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false) }
        let zoomed = model.camera
        model.nudge(.right, at: start + 1)
        for _ in 0..<30 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false) }
        #expect(model.camera == zoomed)
    }

    @MainActor private func makeModel() -> GlobeExperienceModel {
        let model = GlobeExperienceModel()
        model.transitionCamera(to: GeoCoordinate(latitude: 0, longitude: 0),
                               distance: GlobeCameraState.defaultDistance, animated: false, overviewFraming: 0)
        model.activate(initialCenter: nil) { _, _ in [] }
        return model
    }
}
