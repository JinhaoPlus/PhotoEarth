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
    static func anniversaryRecords(empty: Bool) -> [PhotoAssetRecord] {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: .now)
        let earliest = calendar.date(byAdding: .year, value: -12, to: today)!
        let matches = AnniversaryDay.matchingDays(on: today, since: earliest, calendar: calendar)
        let latest = matches[0].lowerBound
        let older = matches[2].lowerBound
        let previous = calendar.date(byAdding: .day, value: -1, to: latest)!
        let groups = [("sample-paris", latest, 52), ("sample-tokyo", older, 3),
                      ("sample-rio", previous, 2)]
        return groups.flatMap { prefix, date, count in
            let coordinate: GeoCoordinate
            switch prefix {
            case "sample-tokyo": coordinate = GeoCoordinate(latitude: 35.6762, longitude: 139.6503)
            case "sample-rio": coordinate = GeoCoordinate(latitude: -22.9068, longitude: -43.1729)
            default: coordinate = GeoCoordinate(latitude: 48.8566, longitude: 2.3522)
            }

            // Keep additional cities beyond the initial five-item preview.
            let stops = prefix == "sample-paris" ? [
                coordinate, GeoCoordinate(latitude: 51.5074, longitude: -0.1278),
                GeoCoordinate(latitude: 50.8503, longitude: 4.3517),
                GeoCoordinate(latitude: 52.3676, longitude: 4.9041)
            ] : [coordinate]
            let base = empty ? calendar.date(byAdding: .day, value: 2, to: date)! : date
            return (1...count).map { number in
                let resources = ["sample-paris", "sample-istanbul", "sample-rio", "sample-sydney", "sample-banff", "sample-cape-town", "sample-singapore"]
                let image = prefix == "sample-paris" ? resources[(number - 1) % resources.count] : prefix
                return PhotoAssetRecord(id: "\(image)-\(number + (prefix == "sample-paris" && image != prefix ? 100 : 0))", coordinate: stops[(number - 1) / 13],
                                 creationDate: base.addingTimeInterval(3600 + Double(number) * 600), pixelWidth: 1600,
                                 pixelHeight: 1000, isFavorite: true, mediaKind: number == 3 ? .video : number == 4 ? .livePhoto : .photo,
                                 duration: number == 3 ? 18 : 0)
            }
        }
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
