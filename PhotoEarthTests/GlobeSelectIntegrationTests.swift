import QuartzCore
import Testing
@testable import PhotoEarth

struct GlobeSelectIntegrationTests {
    private let initialDistance = GlobeCameraState.minimumDistance * 8
    private let center = GeoCoordinate(latitude: 35.68, longitude: 139.76)

    @Test @MainActor func hardwareShortPressDispatchesImmediatelyWithoutZooming() {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        var actions: [RemoteSelectGestureRecognizer.Action] = []
        prepare(model) { actions.append($0) }
        let start = CACurrentMediaTime()

        model.receiveSelectPress(true, source: .hardware, at: start)
        #expect(actions.isEmpty)
        model.receiveSelectPress(false, source: .hardware, at: start + 0.05)
        #expect(actions == [.singlePress])
        for _ in 0..<12 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false) }
        #expect(model.camera.center == center)
        #expect(model.camera.distance == initialDistance)
    }

    @Test @MainActor func rapidShortPressesRemainDistinctActionsAndNeverZoom() {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        var actions: [RemoteSelectGestureRecognizer.Action] = []
        prepare(model) { actions.append($0) }
        let start = CACurrentMediaTime()

        for offset in [0.0, 0.2, 0.4] {
            model.receiveSelectPress(true, source: .hardware, at: start + offset)
            model.receiveSelectPress(false, source: .hardware, at: start + offset + 0.05)
        }
        #expect(actions == [.singlePress, .singlePress, .singlePress])
        for _ in 0..<12 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false) }
        #expect(model.camera.center == center)
        #expect(model.camera.distance == initialDistance)
    }

    @Test @MainActor func clickpadMovementWhilePressedCannotMoveTheSelectionAnchor() {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        var actions: [RemoteSelectGestureRecognizer.Action] = []
        prepare(model) { actions.append($0) }
        let start = CACurrentMediaTime()

        model.receiveSelectPress(true, source: .hardware, at: start)
        model.applyTouchPan(horizontalDelta: 0.2, verticalDelta: -0.1, at: start + 0.02)
        model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false)
        #expect(model.camera.center == center)
        model.receiveSelectPress(false, source: .hardware, at: start + 0.05)
        #expect(actions == [.singlePress])
        #expect(model.camera.center == center)
        #expect(model.camera.distance == initialDistance)
    }

    @Test @MainActor func sustainedCenterPressDispatchesOnePhotoSelectionOnRelease() {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        var actions: [RemoteSelectGestureRecognizer.Action] = []
        prepare(model) { actions.append($0) }
        let start = CACurrentMediaTime()

        model.receiveSelectPress(true, source: .hardware, at: start)
        model.receiveSelectPress(false, source: .hardware, at: start + 0.7)
        model.receiveSelectPress(false, source: .hardware, at: start + 0.8)
        #expect(actions == [.singlePress])
        for _ in 0..<12 { model.advanceMotionFrame(elapsed: 1.0 / 30, reduceMotion: false) }
        #expect(model.camera.center == center)
        #expect(model.camera.distance == initialDistance)
    }

    @Test @MainActor func heldCenterPressHasNoTimedActionBeforeRelease() async throws {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        var actions: [RemoteSelectGestureRecognizer.Action] = []
        prepare(model) { actions.append($0) }

        model.receiveSelectPress(true, source: .hardware)
        try await Task.sleep(for: .milliseconds(800))
        #expect(actions.isEmpty)
        model.receiveSelectPress(false, source: .hardware)
        #expect(actions == [.singlePress])
        #expect(model.camera.center == center)
        #expect(model.camera.distance == initialDistance)
    }

    @Test(arguments: [false, true])
    @MainActor func firstSourceDispatchesEachClickOnceDespiteDuplicateDelivery(hardwareArrivesFirst: Bool) {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        var actions: [RemoteSelectGestureRecognizer.Action] = []
        prepare(model) { actions.append($0) }
        let start = CACurrentMediaTime()
        let owner: GlobeExperienceModel.SelectInputSource = hardwareArrivesFirst ? .hardware : .uiKit
        let other: GlobeExperienceModel.SelectInputSource = hardwareArrivesFirst ? .uiKit : .hardware

        model.receiveSelectPress(true, source: owner, at: start)
        model.receiveSelectPress(true, source: other, at: start + 0.001)
        model.receiveSelectPress(false, source: other, at: start + 0.05)
        #expect(actions.isEmpty)
        model.receiveSelectPress(false, source: owner, at: start + 0.051)
        #expect(actions == [.singlePress])
        // A late duplicate down/up pair must not arm another click.
        model.receiveSelectPress(true, source: other, at: start + 0.07)
        model.receiveSelectPress(false, source: other, at: start + 0.09)
        #expect(actions == [.singlePress])
        #expect(model.camera.distance == initialDistance)
    }

    @Test(arguments: [false, true])
    @MainActor func cancellationFromTheOtherSourceCannotDiscardTheOwnersPress(hardwareArrivesFirst: Bool) {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        var actions: [RemoteSelectGestureRecognizer.Action] = []
        prepare(model) { actions.append($0) }
        let start = CACurrentMediaTime()
        let owner: GlobeExperienceModel.SelectInputSource = hardwareArrivesFirst ? .hardware : .uiKit
        let other: GlobeExperienceModel.SelectInputSource = hardwareArrivesFirst ? .uiKit : .hardware

        model.receiveSelectPress(true, source: owner, at: start)
        model.cancelSelectPresses(source: other)
        model.receiveSelectPress(false, source: owner, at: start + 0.05)
        #expect(actions == [.singlePress])
        model.receiveSelectPress(true, source: owner, at: start + 0.2)
        model.cancelSelectPresses(source: other)
        model.receiveSelectPress(false, source: owner, at: start + 0.9)
        #expect(actions == [.singlePress, .singlePress])
    }

    @Test(arguments: [false, true])
    @MainActor func anotherSourceCanOwnANewPressAfterTheDuplicateTail(hardwareArrivesFirst: Bool) {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        var actions: [RemoteSelectGestureRecognizer.Action] = []
        prepare(model) { actions.append($0) }
        let start = CACurrentMediaTime()
        let owner: GlobeExperienceModel.SelectInputSource = hardwareArrivesFirst ? .hardware : .uiKit
        let other: GlobeExperienceModel.SelectInputSource = hardwareArrivesFirst ? .uiKit : .hardware

        model.receiveSelectPress(true, source: owner, at: start)
        model.receiveSelectPress(false, source: owner, at: start + 0.05)
        model.receiveSelectPress(true, source: other, at: start + 0.07)
        model.receiveSelectPress(false, source: other, at: start + 0.09)
        #expect(actions == [.singlePress])
        model.receiveSelectPress(true, source: other, at: start + 0.3)
        model.receiveSelectPress(false, source: other, at: start + 0.35)
        #expect(actions == [.singlePress, .singlePress])
        #expect(model.camera.distance == initialDistance)
    }

    @Test(arguments: [false, true])
    @MainActor func heldPressIsCancelledWhenExplorationStops(sceneBecomesInactive: Bool) async throws {
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        var actions: [RemoteSelectGestureRecognizer.Action] = []
        prepare(model) { actions.append($0) }
        model.receiveSelectPress(true, source: .hardware)
        if sceneBecomesInactive { model.setSceneActive(false) }
        else { model.pauseDirectManipulation() }

        try await Task.sleep(for: .milliseconds(800))
        #expect(actions.isEmpty)
        if sceneBecomesInactive { model.setSceneActive(true) }
        else { model.resumeDirectManipulation() }
        // The old release after resuming cannot become a short click.
        model.receiveSelectPress(false, source: .hardware)
        #expect(actions.isEmpty)
        model.receiveSelectPress(true, source: .hardware)
        model.receiveSelectPress(false, source: .hardware)
        #expect(actions == [.singlePress])
        #expect(model.camera.center == center)
        #expect(model.camera.distance == initialDistance)
    }

    @MainActor private func prepare(
        _ model: GlobeExperienceModel,
        onSelectAction: @escaping (RemoteSelectGestureRecognizer.Action) -> Void
    ) {
        model.transitionCamera(to: center, distance: initialDistance, animated: false, overviewFraming: 0)
        #expect(model.camera.distance == initialDistance)
        model.activate(initialCenter: nil, onSelectAction: onSelectAction) { _, _ in [] }
    }
}
