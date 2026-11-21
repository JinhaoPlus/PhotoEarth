#if DEBUG
import Testing
@testable import PhotoEarth

struct PreparationFixtureLibraryTests {
    @Test func existingPreparationFixtureRemainsAuthorizedByDefault() async throws {
        let fixture = PreparationFixtureLibrary(records: [])
        #expect(await fixture.authorizationStatus() == .authorized)
        #expect(await fixture.requestAuthorization() == .authorized)
        #expect(try await fixture.scanLocatedPhotos().sourcePhotoCount == 0)
    }

    @Test func welcomeFixtureWaitsForAnExplicitRequestAndRetainsItsDecision() async {
        let fixture = PreparationFixtureLibrary(records: [], initiallyRequiresAuthorization: true)
        #expect(await fixture.authorizationStatus() == .notDetermined)
        #expect(await fixture.authorizationStatus() == .notDetermined)
        #expect(await fixture.requestAuthorization() == .authorized)
        #expect(await fixture.authorizationStatus() == .authorized)
        #expect(await fixture.requestAuthorization() == .authorized)
    }
}
#endif
