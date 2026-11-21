import Foundation
import Testing
@testable import PhotoEarth

struct ScanCameraDirectorTests {
    private func place(_ id: String, latitude: Double = 0, longitude: Double) -> TravelPlace {
        TravelPlace(id: id, name: "地点", country: nil, coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                    startDate: .distantPast, endDate: .distantPast, photoCount: 1, coverAssetID: nil)
    }

    @Test func denseSameRegionEventsDoNotCauseRepeatedFlights() {
        var director = ScanCameraDirector(); director.begin(at: 0)
        director.ingest((0..<50_000).map { place("p-\($0)", longitude: 110) }, at: 0)
        #expect(director.candidateCount == 1)
        let first = director.next(at: 0, center: GeoCoordinate(latitude: 0, longitude: 0), viewport: nil, reduceMotion: false, enabled: true)
        #expect(first != nil)
        director.ingest((50_000..<50_050).map { place("p-\($0)", longitude: 110) }, at: 40)
        #expect(director.next(at: 40, center: GeoCoordinate(latitude: 0, longitude: 0), viewport: nil, reduceMotion: false, enabled: true) == nil)
    }

    @Test func globalEventsRespectEveryRollingMotionBudgetAndRestAfterFiveMinutes() {
        var director = ScanCameraDirector(); director.begin(at: 0)
        var center = GeoCoordinate(latitude: 0, longitude: 0)
        var flights: [(Double, Double)] = []
        for second in 0...360 {
            let time = Double(second)
            director.ingest((0..<30).map { place("\(second)-\($0)", latitude: Double($0 % 5) * 12 - 24, longitude: Double($0) * 12 - 180) }, at: time)
            #expect(director.candidateCount <= 24)
            if let flight = director.next(at: time, center: center, viewport: nil, reduceMotion: false, enabled: true) {
                #expect(time < 300)
                flights.append((time, time + flight.duration))
                center = flight.place.coordinate
            }
        }
        #expect(flights.count > 2)
        for tenth in 0...3600 {
            let end = Double(tenth) / 10
            let movement = flights.reduce(0.0) { $0 + max(0, min($1.1, end) - max($1.0, end - 30)) }
            #expect(movement <= 10.001)
            #expect(flights.filter { $0.0 > end - 60 && $0.0 <= end }.count <= 2)
        }
        for pair in zip(flights, flights.dropFirst()) {
            #expect(pair.1.0 - pair.0.0 >= 20)
            #expect(pair.1.0 - pair.0.1 >= 10)
        }
    }

    @Test func reduceMotionDisabledPageAndNearbyDiscoveryNeverMoveCamera() {
        var director = ScanCameraDirector(); director.begin(at: 0)
        director.ingest([place("far", longitude: 130)], at: 0)
        let center = GeoCoordinate(latitude: 0, longitude: 0)
        #expect(director.next(at: 0, center: center, viewport: nil, reduceMotion: true, enabled: true) == nil)
        #expect(director.next(at: 1, center: center, viewport: nil, reduceMotion: false, enabled: false) == nil)
        director.begin(at: 2)
        director.ingest([place("near", longitude: 4)], at: 2)
        #expect(director.next(at: 2, center: center, viewport: nil, reduceMotion: false, enabled: true) == nil)
        #expect(ScanCameraDirector.angle(GeoCoordinate(latitude: 0, longitude: 179), GeoCoordinate(latitude: 0, longitude: -179)) < 3)
    }

    @Test func reopeningScanDoesNotReplayItsOldDiscoverySnapshot() {
        var director = ScanCameraDirector()
        let old = place("old", longitude: 120)
        director.begin(at: 200, baseline: [old])
        director.ingest([old], at: 201)
        #expect(director.candidateCount == 0)
        var updated = old; updated.name = "测试城市"; updated.country = "测试国家"
        director.ingest([updated], at: 202)
        #expect(director.candidateCount == 1)
        #expect(director.next(at: 202, center: GeoCoordinate(latitude: 0, longitude: 0), viewport: nil, reduceMotion: false, enabled: true) != nil)
    }

    @Test func scanFlightsCrossDateLineByShortArcAndAntipodalFlightsStayFinite() {
        let start = GlobeCameraState(center: GeoCoordinate(latitude: 0, longitude: 179), distance: 10000000)
        let end = GlobeCameraState(center: GeoCoordinate(latitude: 0, longitude: -179), distance: 10000000)
        var flight = GlobeCameraFlight(origin: start, destination: end, duration: 4, usesGreatCircle: true)
        let midpoint = flight.advance(by: 2)
        #expect(abs(midpoint.center.longitude) > 179.9)
        #expect(flight.advance(by: 2) == end)
        let opposite = GlobeCameraState(center: GeoCoordinate(latitude: 0, longitude: -1), distance: 10000000)
        var antipodal = GlobeCameraFlight(origin: start, destination: opposite, duration: 4, usesGreatCircle: true)
        var previous = start
        for _ in 0..<120 {
            let next = antipodal.advance(by: 4.0 / 120)
            #expect(next.center.isValid)
            #expect(ScanCameraDirector.angle(previous.center, next.center) < 3)
            previous = next
        }
    }

    @Test func expiredCandidatesAreNotReplayedAndLODKeepsChosenTargetWithinBudget() {
        var director = ScanCameraDirector(); director.begin(at: 0)
        let target = place("target", longitude: 179)
        director.ingest([target], at: 0)
        #expect(director.next(at: 121, center: GeoCoordinate(latitude: 0, longitude: 0), viewport: nil, reduceMotion: false, enabled: true) == nil)
        let places = (0..<300).map { place("a-\($0)", latitude: Double($0 % 70) - 35, longitude: Double($0 % 150) - 75) } + [target]
        let selected = MapPlaceLOD.representatives(from: places, limit: 180, preferredPlaceID: target.id)
        #expect(selected.count <= 180)
        #expect(selected.first?.id == target.id)
    }
}
