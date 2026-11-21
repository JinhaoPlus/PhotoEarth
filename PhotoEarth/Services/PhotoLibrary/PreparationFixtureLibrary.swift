#if DEBUG
import Foundation

/// Explicitly selected, neutral UI fixture. It exercises the actual preparation
/// coordinator and SQLite pipeline without permission, private assets or MapKit requests.
nonisolated final class PreparationFixtureLibrary: PhotoLibraryUpdating, Sendable {
    static var transitRecords: [PhotoAssetRecord] {
        let source = SampleTravelIndex.make().photos
        let stay = Array(source.filter { $0.placeID == "sample-paris" }.prefix(3))
        let pass = source.first { $0.placeID == "sample-tokyo" && !$0.isFavorite }!
        return ProcessInfo.processInfo.arguments.contains("--transit-only-fixture") ? [pass] : stay + [pass]
    }
    let records: [PhotoAssetRecord]
    private let authorization: FixtureAuthorization

    init(records: [PhotoAssetRecord], initiallyRequiresAuthorization: Bool = false) {
        self.records = records
        authorization = FixtureAuthorization(status: initiallyRequiresAuthorization ? .notDetermined : .authorized)
    }
    func authorizationStatus() async -> PhotoLibraryAccess { await authorization.status }
    func requestAuthorization() async -> PhotoLibraryAccess { await authorization.authorize() }
    func scanLocatedPhotos() async throws -> PhotoLibraryScan { PhotoLibraryScan(sourcePhotoCount: records.count, locatedPhotos: records) }
    func currentChangeToken() async throws -> Data { Data("fixture-baseline".utf8) }
    func enumeratePhotos(_ receive: @escaping @Sendable (PhotoMetadataBatch) async throws -> Void) async throws -> Int {
        for start in stride(from: 0, to: records.count, by: 12) {
            try await Task.sleep(for: .milliseconds(350))
            let end = min(start + 12, records.count)
            try await receive(PhotoMetadataBatch(records: Array(records[start..<end]), checked: end, total: records.count))
        }
        return records.count
    }
    func enumerateChanges(since token: Data, _ receive: @escaping @Sendable (PhotoMetadataBatch) async throws -> Void) async throws -> LibraryChangeResult {
        LibraryChangeResult(token: token, sourcePhotoCount: records.count, changedAssetCount: 0)
    }
    func observeChanges(_ onChange: @escaping @Sendable () -> Void) {}
    func stopObservingChanges() {}

    private actor FixtureAuthorization {
        var status: PhotoLibraryAccess
        init(status: PhotoLibraryAccess) { self.status = status }
        func authorize() -> PhotoLibraryAccess {
            status = .authorized
            return status
        }
    }
}
#endif
