import Foundation

nonisolated enum AnniversaryDay {
    static func years(from earliest: Int?, through current: Int) -> [Int] {
        Array((min(earliest ?? current, current)...current).reversed())
    }

    static func matchingDays(on today: Date, since earliest: Date, calendar: Calendar) -> [Range<Date>] {
        let current = calendar.dateComponents([.year, .month, .day], from: today)
        guard let year = current.year, let month = current.month, let day = current.day else { return [] }
        let first = calendar.component(.year, from: earliest)
        return years(from: first, through: year).compactMap { candidateYear in
            guard let date = calendar.anniversaryDate(month: month, day: day, year: candidateYear),
                  let interval = calendar.dateInterval(of: .day, for: date) else { return nil }
            return interval.start..<interval.end
        }
    }
}

nonisolated extension Calendar {
    /// A leap reference year lets the month/day picker address February 29 in any current year.
    func anniversaryDate(month: Int, day: Int, year: Int = 2000) -> Date? {
        guard let date = date(from: DateComponents(year: year, month: month, day: day)),
              component(.month, from: date) == month, component(.day, from: date) == day else { return nil }
        return date
    }
}
