import Testing
@testable import PhotoEarth

struct SiriRemoteSymbolTests {
    @Test func missingOrInvalidControllerSymbolsUseStablePublicFallbacks() {
        let missing = SiriRemoteSymbolNames()
        #expect(missing.touchSurface == "hand.draw")
        #expect(missing.directionalPad == "arrow.up.and.down.and.arrow.left.and.right")
        #expect(missing.centerButton == "circle.inset.filled")
        #expect(missing.playPauseButton == "playpause.fill")

        let invalid = SiriRemoteSymbolNames(
            touchSurface: "not.a.system.symbol",
            directionalPad: "",
            centerButton: "not.a.system.symbol",
            playPauseButton: "not.a.system.symbol"
        )
        #expect(invalid == missing)
    }

    @Test func availableControllerSymbolsArePreserved() {
        let names = SiriRemoteSymbolNames(
            touchSurface: "hand.tap.fill",
            directionalPad: "dpad.fill",
            centerButton: "circle.circle.fill",
            playPauseButton: "playpause.circle.fill"
        )
        #expect(names.touchSurface == "hand.tap.fill")
        #expect(names.directionalPad == "dpad.fill")
        #expect(names.centerButton == "circle.circle.fill")
        #expect(names.playPauseButton == "playpause.circle.fill")
    }

    @Test func genericGamepadFaceButtonsDoNotMasqueradeAsRemoteButtons() {
        let names = SiriRemoteSymbolNames(
            centerButton: "a.circle.fill",
            playPauseButton: "xmark.circle.fill"
        )
        #expect(names.centerButton == "circle.inset.filled")
        #expect(names.playPauseButton == "playpause.fill")
    }
}
