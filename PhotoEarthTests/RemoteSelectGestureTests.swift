import Testing
@testable import PhotoEarth

struct RemoteSelectGestureTests {
    @Test func pressActsOnceOnReleaseWithoutAnArbitrationWindow() {
        var input = RemoteSelectGestureRecognizer()
        #expect(input.pressBegan(at: 1).isEmpty)
        #expect(input.pressEnded(at: 1.08) == [.singlePress])
        #expect(input.pressEnded(at: 1.09).isEmpty)
    }

    @Test func sustainedPressHasNoSeparateHoldAction() {
        var input = RemoteSelectGestureRecognizer()
        #expect(input.pressBegan(at: 1).isEmpty)
        #expect(input.pressBegan(at: 10).isEmpty)
        #expect(input.pressEnded(at: 20) == [.singlePress])
        #expect(input.pressEnded(at: 21).isEmpty)
    }

    @Test func rapidClicksRemainIndependentPresses() {
        var input = RemoteSelectGestureRecognizer()
        for start in [1.0, 1.15, 1.3] {
            #expect(input.pressBegan(at: start).isEmpty)
            #expect(input.pressEnded(at: start + 0.05) == [.singlePress])
        }
    }

    @Test func duplicateEdgesDoNotRepeatTheAction() {
        var input = RemoteSelectGestureRecognizer()
        #expect(input.pressBegan(at: 1).isEmpty)
        #expect(input.pressBegan(at: 1.2).isEmpty)
        #expect(input.pressEnded(at: 1.3) == [.singlePress])
        #expect(input.pressEnded(at: 1.4).isEmpty)
    }

    @Test func cancellationDiscardsTheActivePress() {
        var input = RemoteSelectGestureRecognizer()
        #expect(input.pressBegan(at: 1).isEmpty)
        input.reset()
        #expect(input.pressEnded(at: 2).isEmpty)
        #expect(input.pressBegan(at: 3).isEmpty)
        #expect(input.pressEnded(at: 3.1) == [.singlePress])
    }

    @Test func invalidAndOutOfOrderTimesCannotMutateTheGesture() {
        var input = RemoteSelectGestureRecognizer()
        #expect(input.pressBegan(at: .nan).isEmpty)
        #expect(input.pressBegan(at: -.infinity).isEmpty)
        #expect(input.pressBegan(at: -1).isEmpty)
        #expect(input.pressBegan(at: 10).isEmpty)
        #expect(input.pressEnded(at: 9).isEmpty)
        #expect(input.pressEnded(at: .infinity).isEmpty)
        #expect(input.pressEnded(at: 10.1) == [.singlePress])
        #expect(input.pressBegan(at: 10.05).isEmpty)
    }

    @Test func cancellationRetainsTheMonotonicWatermark() {
        var input = RemoteSelectGestureRecognizer()
        #expect(input.pressBegan(at: 10).isEmpty)
        input.reset()
        #expect(input.pressBegan(at: 9).isEmpty)
        #expect(input.pressEnded(at: 9.1).isEmpty)
        #expect(input.pressBegan(at: 11).isEmpty)
        #expect(input.pressEnded(at: 11.1) == [.singlePress])
    }
}
