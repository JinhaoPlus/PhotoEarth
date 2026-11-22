import Foundation
import Testing
@testable import PhotoEarth

struct OnThisDayTests {
    @Test func localDatesExcludeThisYearAndNeverMoveLeapDayIntoMarch() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        func date(_ y: Int, _ m: Int, _ d: Int) throws -> Date {
            try #require(cal.date(from: DateComponents(year: y, month: m, day: d)))
        }
        let ranges = try AnniversaryDay.pastDays(on: date(2024, 2, 29), since: date(2016, 1, 1), calendar: cal)
        #expect(ranges.map(\.lowerBound) == [try date(2020, 2, 29), try date(2016, 2, 29)])
        let dst = try AnniversaryDay.pastDays(on: date(2026, 3, 9), since: date(2025, 1, 1), calendar: cal)
        let day = try #require(dst.first)
        #expect(day.upperBound.timeIntervalSince(day.lowerBound) == 23 * 3600)
        #expect(!day.contains(day.upperBound))
    }

    @Test func sqliteCountsAndPagesExcludeRevokedAndNeighboringPhotos() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SQLiteTravelIndexStore(databaseURL: url.appendingPathComponent("index.sqlite"))
        let fixture = SampleTravelIndex.makeMapReviewFixture()
        try await store.save(fixture)
        let ordered = fixture.photos.sorted { $0.creationDate > $1.creationDate }
        let range = ordered[90].creationDate..<ordered[8].creationDate
        let excluded: Set<String> = [ordered[9].id, ordered[58].id]
        let expected = ordered.filter { range.contains($0.creationDate) && !excluded.contains($0.id) }
        let reader = try await store.photoReadSnapshot()
        let days = try await reader.anniversaryDays(in: [range], excluding: excluded)
        #expect(days.first?.count == expected.count)
        #expect(days.first?.cover.id == expected.first?.id)
        let first = try await reader.anniversaryPage(in: range, excluding: excluded, offset: 0)
        let offset = try #require(first.nextOffset)
        let second = try await reader.anniversaryPage(in: range, excluding: excluded, offset: offset)
        #expect(first.records + second.records == expected)
        #expect(second.nextOffset == nil)
    }
}
