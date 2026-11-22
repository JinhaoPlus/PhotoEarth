import Foundation

nonisolated struct AnniversaryDay: Identifiable, Equatable, Sendable {
    let range: Range<Date>
    let cover: PhotoAssetRecord
    let count: Int
    var id: Date { range.lowerBound }

    static func pastDays(on today: Date, since earliest: Date, calendar: Calendar) -> [Range<Date>] {
        let current = calendar.dateComponents([.year, .month, .day], from: today)
        guard let year = current.year, let month = current.month, let day = current.day else { return [] }
        let first = calendar.component(.year, from: earliest)
        guard first < year else { return [] }
        return (first..<year).reversed().compactMap { pastYear in
            guard let date = calendar.date(from: DateComponents(year: pastYear, month: month, day: day)),
                  calendar.component(.day, from: date) == day,
                  let interval = calendar.dateInterval(of: .day, for: date) else { return nil }
            return interval.start..<interval.end
        }
    }
}
