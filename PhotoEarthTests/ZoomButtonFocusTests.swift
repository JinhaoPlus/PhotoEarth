import SwiftUI
import Testing
import UIKit
@testable import PhotoEarth

@Suite(.serialized)
struct ZoomButtonFocusTests {
    @Test @MainActor func styleAndCityScopeRemainSeparateFocusableActions() {
        let navigation = ZoomButtonFocusNavigation()
        navigation.includesMapStyle = true
        navigation.moveFocus(for: .rightArrow)
        #expect(navigation.request.target == .mapStyle)
        navigation.moveFocus(for: .rightArrow)
        #expect(navigation.request.target == .mapStyle)
        navigation.includesCurrentView = true
        navigation.didFocus(.zoomIn)
        navigation.moveFocus(for: .rightArrow)
        #expect(navigation.request.target == .currentView)
        navigation.moveFocus(for: .rightArrow)
        #expect(navigation.request.target == .mapStyle)
        navigation.moveFocus(for: .rightArrow)
        #expect(navigation.request.target == .mapStyle)
    }
    @Test(arguments: [UIFocusHeading.left, .right, .up, .down]) @MainActor
    func nativeDirectionalUpdatesCannotMoveBetweenDockButtons(heading: UIFocusHeading) {
        let navigation = ZoomButtonFocusNavigation()
        let host = ZoomButtonHostingController(rootView: EmptyView(), navigation: navigation,
                                              assistiveNavigationIsActive: { false })
        #expect(!host.allowsNativeFocus(heading: heading))
        host.receiveDirectionalPress(.rightArrow)
        #expect(!host.allowsNativeFocus(heading: heading),
                "A physical press must not open a time window for native swipe focus")
    }

    @Test @MainActor
    func physicalArrowsRequestTheAdjacentButtonAndPreserveBoundaries() {
        let navigation = ZoomButtonFocusNavigation()
        let host = ZoomButtonHostingController(rootView: EmptyView(), navigation: navigation,
                                              assistiveNavigationIsActive: { false })
        #expect(navigation.request.target == .zoomIn)
        host.receiveDirectionalPress(.leftArrow)
        #expect(navigation.request.target == .zoomOut)
        navigation.didFocus(.zoomOut)
        host.receiveDirectionalPress(.leftArrow)
        #expect(navigation.request.target == .zoomOut)
        host.receiveDirectionalPress(.rightArrow)
        #expect(navigation.request.target == .zoomIn)
        navigation.didFocus(.zoomIn)
        host.receiveDirectionalPress(.rightArrow)
        #expect(navigation.request.target == .zoomIn)
        host.receiveDirectionalPress(.rightArrow)
        #expect(navigation.request.target == .zoomIn)
        let request = navigation.request
        for press: UIPress.PressType in [.upArrow, .downArrow, .select, .menu] {
            host.receiveDirectionalPress(press)
            #expect(navigation.request == request,
                    "Only physical horizontal arrows request a different zoom button")
        }
    }

    @Test @MainActor
    func physicalArrowsFollowTheMirroredButtonLayout() {
        let navigation = ZoomButtonFocusNavigation()
        navigation.layoutDirection = .rightToLeft
        navigation.includesMapStyle = true
        navigation.moveFocus(for: .leftArrow)
        #expect(navigation.request.target == .mapStyle)
        navigation.moveFocus(for: .leftArrow)
        #expect(navigation.request.target == .mapStyle)
        navigation.moveFocus(for: .rightArrow)
        #expect(navigation.request.target == .zoomIn)
        navigation.moveFocus(for: .rightArrow)
        #expect(navigation.request.target == .zoomOut)
    }

    @Test @MainActor
    func initialProgrammaticAndFocusLossUpdatesRemainAllowed() {
        let host = ZoomButtonHostingController(rootView: EmptyView(), navigation: ZoomButtonFocusNavigation(),
                                              assistiveNavigationIsActive: { false })
        #expect(host.allowsNativeFocus(heading: []))
    }

    @Test @MainActor
    func assistiveNavigationBypassesVetoWithoutDuplicatingButtonMoves() throws {
        var assistiveNavigation = true
        let navigation = ZoomButtonFocusNavigation()
        let host = ZoomButtonHostingController(rootView: EmptyView(), navigation: navigation,
                                              assistiveNavigationIsActive: { assistiveNavigation })
        let recognizer = try #require(host.view.gestureRecognizers?.compactMap {
            $0 as? ZoomButtonDirectionPressRecognizer
        }.first)
        #expect(!recognizer.isEnabled)
        let initialRequest = navigation.request
        host.receiveDirectionalPress(.leftArrow)
        #expect(navigation.request == initialRequest)
        #expect(host.allowsNativeFocus(heading: .left))
        assistiveNavigation = false
        host.synchronizeRouting()
        #expect(recognizer.isEnabled)
        host.receiveDirectionalPress(.leftArrow)
        #expect(navigation.request.target == .zoomOut)
        #expect(!host.allowsNativeFocus(heading: .left))
    }

    @Test @MainActor
    func disabledDockDropsPressesAndStopsRestrictingFocus() throws {
        let navigation = ZoomButtonFocusNavigation()
        let host = ZoomButtonHostingController(rootView: EmptyView(), navigation: navigation,
                                              assistiveNavigationIsActive: { false })
        host.routingEnabled = false
        let request = navigation.request
        host.receiveDirectionalPress(.leftArrow)
        #expect(navigation.request == request)
        let recognizer = try #require(host.view.gestureRecognizers?.compactMap {
            $0 as? ZoomButtonDirectionPressRecognizer
        }.first)
        #expect(!recognizer.isEnabled, "A disabled dock must release the physical press recognizer too")
        #expect(host.allowsNativeFocus(heading: .right))
        host.routingEnabled = true
        #expect(recognizer.isEnabled)
        host.receiveDirectionalPress(.leftArrow)
        #expect(navigation.request.target == .zoomOut)
    }

    @Test @MainActor
    func hostedSwiftUIButtonsHaveARealFocusAncestorAndAcceptProgrammaticMoves() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        let navigation = ZoomButtonFocusNavigation()
        let host = ZoomButtonHostingController(rootView: FocusButtonFixture(navigation: navigation),
                                              navigation: navigation,
                                              assistiveNavigationIsActive: { false })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.routingEnabled = false
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        let system = try #require(UIFocusSystem.focusSystem(for: host))
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        let first = try await waitForStableFocus(target: .zoomIn, navigation: navigation,
                                                host: host, system: system)
        #expect(host.contains(first),
                "The production hosting controller must be an ancestor of the actual SwiftUI focus item")
        host.receiveDirectionalPress(.leftArrow)
        let second = try await waitForStableFocus(target: .zoomOut, navigation: navigation,
                                                 host: host, system: system, excluding: first)
        #expect(first !== second, "The programmatic request must move real system Focus")
        #expect(host.contains(second))
        host.receiveDirectionalPress(.rightArrow)
        _ = try await waitForStableFocus(target: .zoomIn, navigation: navigation,
                                        host: host, system: system, matching: first)
        #expect(system.focusedItem === first)
    }

    @MainActor
    private func waitForStableFocus(target: ZoomButtonFocusTarget, navigation: ZoomButtonFocusNavigation,
                                    host: UIFocusEnvironment, system: UIFocusSystem,
                                    excluding previous: UIFocusItem? = nil,
                                    matching expected: UIFocusItem? = nil) async throws -> UIFocusItem {
        // SwiftUI's native Focus item need not expose its accessibility identifier.
        // UI tests identify the exact zoom buttons; this integration test verifies
        // real Focus ownership, movement and restoration through the production host.
        var candidate: UIFocusItem?
        var stableSamples = 0
        for _ in 0..<100 {
            system.updateFocusIfNeeded()
            if navigation.currentControl == target, navigation.request.target == target,
               let item = system.focusedItem, host.contains(item),
               previous == nil || item !== previous,
               expected == nil || item === expected {
                stableSamples = candidate === item ? stableSamples + 1 : 1
                candidate = item
                // Six samples separated by 20 ms reject transient initial Focus.
                if stableSamples >= 6 { return item }
            } else {
                candidate = nil
                stableSamples = 0
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(stableSamples >= 6,
                     "Programmatic Focus must settle inside the host on the expected native item")
        return try #require(candidate)
    }
}

private struct FocusButtonFixture: View {
    @ObservedObject var navigation: ZoomButtonFocusNavigation
    @FocusState private var focused: ZoomButtonFocusTarget?

    var body: some View {
        HStack(spacing: 40) {
            ForEach(ZoomButtonFocusTarget.allCases, id: \.self) { target in
                Button("Button \(target.rawValue)") {}
                    .frame(width: 250, height: 90)
                    .focused($focused, equals: target)
                    .accessibilityIdentifier("zoom-focus-test-\(target.rawValue)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = navigation.request.target }
        .onChange(of: navigation.request) { _, request in focused = request.target }
        .onChange(of: focused) { _, target in navigation.didFocus(target) }
    }
}
