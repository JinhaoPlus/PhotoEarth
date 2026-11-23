import SwiftUI

struct AnniversaryDatePicker: View {
    let date: Date
    let calendar: Calendar
    let years: [Int]
    let browser: AnniversaryBrowser?
    let model: AppModel
    let choose: (Date?) -> Void
    @State private var month = 1
    @State private var marked = Set<Int>()

    private struct MarksQuery: Equatable {
        let month: Int
        let session: ObjectIdentifier?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                Menu {
                    ForEach(1...12, id: \.self) { value in
                        Button(monthName(value)) { month = value }
                    }
                } label: { Label(monthName(month), systemImage: "chevron.up.chevron.down") }
                .accessibilityIdentifier("anniversary-month")
                Spacer()
                Button(String(localized: "anniversary.today")) { choose(nil) }
                    .accessibilityIdentifier("anniversary-today")
            }
            let first = calendar.anniversaryDate(month: month, day: 1)!
            let length = calendar.range(of: .day, in: .month, for: first)!.count
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 18) {
                ForEach(1...length, id: \.self) { day in
                    let value = calendar.anniversaryDate(month: month, day: day)!
                    Button { choose(value) } label: {
                        Text(verbatim: String(day)).monospacedDigit()
                            .fontWeight(calendar.isDate(value, inSameDayAs: date) ? .bold : .regular)
                            .frame(width: 55)
                            .overlay(alignment: .bottom) {
                                if marked.contains(day) { Circle().frame(width: 6, height: 6).offset(y: 7) }
                            }
                    }
                    .accessibilityLabel(value.formatted(.dateTime.month(.wide).day().locale(AppLocalization.locale)))
                    .accessibilityAddTraits(calendar.isDate(value, inSameDayAs: date) ? .isSelected : [])
                    .accessibilityIdentifier("anniversary-pick-\(month)-\(day)")
                }
            }
        }
        .buttonStyle(.glass)
        .padding(64)
        .frame(maxWidth: 940)
        .onAppear { month = calendar.component(.month, from: date) }
        .task(id: MarksQuery(month: month, session: browser.map(ObjectIdentifier.init))) {
            marked = []
            guard let browser else { return }
            let ranges = years.compactMap { calendar.anniversaryDate(month: month, day: 1, year: $0) }
                .compactMap { calendar.dateInterval(of: .month, for: $0) }
            if let reader = browser.reader {
                let days = try? await reader.anniversaryCalendarDays(months: ranges, excluding: browser.excluded)
                if !Task.isCancelled { marked = days ?? [] }
            } else {
                marked = model.anniversarySampleDays(months: ranges, calendar: calendar)
            }
        }
    }

    private func monthName(_ value: Int) -> String {
        calendar.anniversaryDate(month: value, day: 1)!.formatted(.dateTime.month(.wide).locale(AppLocalization.locale))
    }
}
