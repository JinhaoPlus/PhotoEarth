import Foundation
import Testing
import UIKit
@testable import PhotoEarth

struct RemoteIndirectTouchTests {
    @Test func movementWithoutBeganIsIgnored() {
        var input = RemoteIndirectTouchState()
        for x in [0.0, 100, 1_000, -1_000] { #expect(input.moved(x: x, y: 0) == nil) }
        #expect(!input.isTouching)
    }

    @Test func restingContactAndRepeatedSmallJitterNeverBecomeMovement() {
        var input = freshContact()
        #expect(input.moved(x: 0, y: 0) == nil)
        for _ in 0..<100 {
            for (x, y) in [(4.0, 3.0), (-4, -3), (0, 0)] {
                #expect(input.moved(x: x, y: y) == nil)
            }
        }
        #expect(input.isTouching)
        #expect(!input.isPanning)
        input.ended()
        #expect(input.moved(x: 900, y: 0) == nil)
    }

    @Test func firstMovedLandingIsNotReplayedAtActivation() {
        var input = freshContact()
        #expect(input.moved(x: 6, y: 0) == nil)
        #expect(input.moved(x: 12, y: 0) == nil)
        #expect(input.moved(x: 18, y: 0) == .pan(horizontalDelta: 12.0 / 540, verticalDelta: 0))
    }

    @Test func slowDragAccumulatesAndEstablishedReversalsAreImmediate() {
        var input = freshContact()
        _ = input.moved(x: 0, y: 0)
        var total = 0.0
        for x in 1...80 {
            if case let .pan(dx, _) = input.moved(x: Double(x), y: 0) { total += dx }
        }
        #expect(abs(total - 80.0 / 540) < 0.000_001)
        if case let .pan(dx, _) = input.moved(x: 79.5, y: 0) {
            #expect(abs(dx + 0.5 / 540) < 0.000_001)
        } else { Issue.record("A confirmed drag must retain a sub-point reversal") }
    }

    @Test func consistentFastSwipeBeginsWithoutReplayingFirstLandingSegment() {
        var input = freshContact()
        #expect(input.moved(x: 180, y: 0) == nil)
        #expect(input.moved(x: 360, y: 0) == .pan(horizontalDelta: 1.0 / 3, verticalDelta: 0))
    }

    @Test func isolatedLargeRelocationBeforeIntentDoesNotJump() {
        var input = freshContact()
        for x in [0.0, 3, 900, 904, 900] { #expect(input.moved(x: x, y: 0) == nil) }
        #expect(!input.isPanning)
    }

    @Test func aConfirmedDragCanMoveBeyondWindowEdgesWithoutClipping() {
        var input = establishedContact()
        #expect(input.moved(x: 2_180, y: 0) == .pan(horizontalDelta: 4, verticalDelta: 0))
        #expect(input.moved(x: -1_060, y: 0) == .pan(horizontalDelta: -6, verticalDelta: 0))
    }

    @Test func pointTravelUsesSameScaleOnBothAxesAndConvertsUIKitY() {
        var input = freshContact()
        _ = input.moved(x: 0, y: 0)
        #expect(input.moved(x: 54, y: 54) == .pan(horizontalDelta: 0.1, verticalDelta: -0.1))
    }

    @Test func pressOwnsContactUntilRealLiftAndNewLanding() {
        var input = establishedContact()
        input.claimForPress()
        #expect(input.contactOwnedByPress)
        #expect(!input.isPanning)
        for x in [40.0, 80, 0, 900] { #expect(input.moved(x: x, y: 0) == nil) }
        // A duplicate began is not a new contact and cannot erase ownership.
        input.began(x: 0, y: 0, pointsPerUnit: 540, isPressing: false)
        #expect(input.moved(x: 20, y: 0) == nil)
        input.ended()
        input.began(x: 0, y: 0, pointsPerUnit: 540, isPressing: false)
        #expect(input.moved(x: 0, y: 0) == nil)
        #expect(input.moved(x: 20, y: 0) != nil)
    }

    @Test func contactBeginningUnderAHeldPhysicalPressCannotPan() {
        var input = RemoteIndirectTouchState()
        input.began(x: 0, y: 0, pointsPerUnit: 540, isPressing: true)
        for x in [0.0, 20, 100] { #expect(input.moved(x: x, y: 0) == nil) }
        input.ended()
        #expect(!input.contactOwnedByPress)
    }

    @Test func cancellationEndsMotionWithoutReplayingLiftPosition() {
        var input = establishedContact()
        input.ended()
        #expect(!input.isPanning)
        #expect(!input.isTouching)
        #expect(input.moved(x: -1_000, y: 0) == nil)
    }

    @Test @MainActor func captureOnlyAllowsIndirectTouchesAndPreservesNativePressRecognizers() {
        let capture = IndirectTouchPanRecognizer()
        #expect(capture.allowedTouchTypes == [NSNumber(value: UITouch.TouchType.indirect.rawValue)])
        #expect(capture.allowedPressTypes.isEmpty)
        #expect(!capture.cancelsTouchesInView)
        #expect(!capture.canPrevent(UITapGestureRecognizer()))
        #expect(!capture.canPrevent(UILongPressGestureRecognizer()))
        #expect(capture.gestureRecognizer(capture, shouldRecognizeSimultaneouslyWith: UITapGestureRecognizer()))
    }

    @Test @MainActor func availabilityDeliveryIsDeferredAndDropsSupersededInstallation() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let capture = RemoteTouchPanCapture.CaptureView()
        window.addSubview(capture)
        let originalRecognizers = Set((window.gestureRecognizers ?? []).map(ObjectIdentifier.init))
        var availability: [Bool] = []
        capture.configure(
            isEnabled: true, acceptsTouches: { true },
            onContactChanged: { _ in }, onPan: { _, _ in }, onPressClaimed: {},
            onAvailabilityChanged: { availability.append($0) }
        )
        let installed = (window.gestureRecognizers ?? []).filter {
            !originalRecognizers.contains(ObjectIdentifier($0))
        }
        #expect(installed.count == 2)
        capture.detach()
        #expect(availability.isEmpty)
        for _ in 0..<10 where availability.isEmpty { await Task.yield() }
        #expect(availability == [false])
        #expect(installed.allSatisfy { $0.view == nil })
        let remaining = Set((window.gestureRecognizers ?? []).map(ObjectIdentifier.init))
        #expect(originalRecognizers.isSubset(of: remaining), "Detaching must preserve the window's system recognizers")
    }

    private func freshContact() -> RemoteIndirectTouchState {
        var input = RemoteIndirectTouchState()
        input.began(x: 0, y: 0, pointsPerUnit: 540, isPressing: false)
        return input
    }

    private func establishedContact() -> RemoteIndirectTouchState {
        var input = freshContact()
        _ = input.moved(x: 0, y: 0)
        _ = input.moved(x: 20, y: 0)
        return input
    }
}
