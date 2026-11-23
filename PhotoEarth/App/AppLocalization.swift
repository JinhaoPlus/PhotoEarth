import Foundation

/// The app has no independent language preference. The bundle follows the
/// Apple TV / per-app language, while formats retain the user's regional rules.
nonisolated enum AppLocalization {
    enum SupportedLanguage: String, CaseIterable, Sendable {
        case english = "en"
        case japanese = "ja"
        case german = "de"
        case french = "fr"
        case spanish = "es"
        case italian = "it"
        case simplifiedChinese = "zh-Hans"
        case traditionalChinese = "zh-Hant"
    }

    /// Bundle localization selection respects both the Apple TV language list
    /// and a per-app language selected in Settings. Unsupported languages have
    /// already fallen back to the English development localization here.
    static var locale: Locale {
        let language = Bundle.main.preferredLocalizations.first
            .map { Self.language(for: Locale(identifier: $0)) }
            ?? Self.language(for: .autoupdatingCurrent)
        guard let region = Locale.autoupdatingCurrent.region?.identifier else {
            return Locale(identifier: language.rawValue)
        }
        return Locale(identifier: "\(language.rawValue)-\(region)")
    }
    static var localeIdentifier: String { language(for: locale).rawValue }

    static func language(for locale: Locale) -> SupportedLanguage {
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        let languageCode = locale.language.languageCode?.identifier.lowercased()
            ?? identifier.split(separator: "-").first.map(String.init)
            ?? "en"

        switch languageCode {
        case "ja": return .japanese
        case "de": return .german
        case "fr": return .french
        case "es": return .spanish
        case "it": return .italian
        case "zh":
            let script = locale.language.script?.identifier.lowercased()
            return script == "hant"
                ? .traditionalChinese
                : .simplifiedChinese
        default: return .english
        }
    }

    static func supportedLocale(for locale: Locale) -> Locale {
        let language = language(for: locale)
        guard let region = locale.region?.identifier else {
            return Locale(identifier: language.rawValue)
        }
        return Locale(identifier: "\(language.rawValue)-\(region)")
    }

    static func string(
        _ key: StaticString,
        defaultValue: String,
        locale: Locale = locale
    ) -> String {
        String(
            localized: key,
            defaultValue: String.LocalizationValue(stringLiteral: defaultValue),
            bundle: localizationBundle(for: locale),
            locale: locale
        )
    }

    private static func localizationBundle(for locale: Locale) -> Bundle {
        let localization = language(for: locale).rawValue
        guard let path = Bundle.main.path(forResource: localization, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }

    static var unresolvedPlace: String {
        string("place.unresolved", defaultValue: "Place name unavailable")
    }

    static func unknownPlace(near country: String?, locale: Locale = locale) -> String {
        let country = (country ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !country.isEmpty else {
            return string("place.unknown", defaultValue: "Unknown place", locale: locale)
        }
        let format = string(
            "place.unknown_near_country",
            defaultValue: "Unknown place@%@",
            locale: locale
        )
        return String(format: format, locale: locale, arguments: [country])
    }

    static func format(
        _ key: StaticString,
        defaultValue: String,
        _ arguments: CVarArg...
    ) -> String {
        String(format: string(key, defaultValue: defaultValue), locale: locale, arguments: arguments)
    }

    static func number(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }

    static func photoCount(_ count: Int, locale: Locale = locale) -> String {
        let format = string("count.photo", defaultValue: "%lld photos", locale: locale)
        return String(format: format, locale: locale, arguments: [Int64(count)])
    }

    static func itemCount(_ count: Int, locale: Locale = locale) -> String {
        let format = string("count.item", defaultValue: "%lld items", locale: locale)
        return String(format: format, locale: locale, arguments: [Int64(count)])
    }

    static func visitFilterNotice(belowMinimum: Bool, hiddenTransitItems: Int) -> (title: String, help: String)? {
        if belowMinimum {
            return (string("journey.minimum.empty", defaultValue: "No visits meet the minimum"),
                    string("journey.minimum.help", defaultValue: "Lower the minimum per visit in Settings."))
        }
        if hiddenTransitItems > 0 {
            return (string("home.transit_empty", defaultValue: "Likely transit photos are hidden"),
                    string("home.transit_help", defaultValue: "Turn off the transit filter in Settings to show them."))
        }
        return nil
    }

    static func globeInputHint(supportsTouchPan: Bool) -> String {
        supportsTouchPan
            ? string("globe.controls.touch_accessibility", defaultValue: "Swipe on the clickpad or touch surface to drag it, or press the clickpad ring to turn it. Press the clickpad center or touch surface to view photos. Press Play/Pause to open zoom controls.")
            : string("globe.controls.accessibility", defaultValue: "Use the direction buttons to turn it. Press the center button to view photos. Press Play/Pause to open zoom controls.")
    }

    static func placeCount(_ count: Int, locale: Locale = locale) -> String {
        let format = string("count.place", defaultValue: "%lld places", locale: locale)
        return String(format: format, locale: locale, arguments: [Int64(count)])
    }

    static func visitCount(_ count: Int, locale: Locale = locale) -> String {
        let format = string("count.visit", defaultValue: "%lld visits", locale: locale)
        return String(format: format, locale: locale, arguments: [Int64(count)])
    }

    static func cityCount(_ count: Int, locale: Locale = locale) -> String {
        let format = string("count.city", defaultValue: "%lld cities", locale: locale)
        return String(format: format, locale: locale, arguments: [Int64(count)])
    }

    static func mediaDuration(_ interval: TimeInterval, locale: Locale = locale) -> String {
        let seconds = max(0, Int64(exactly: interval.rounded()) ?? 0)
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3_600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(seconds).formatted(.time(pattern: pattern).locale(locale))
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().locale(locale))
    }

    static func monthTitle(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.wide).locale(locale))
    }

    /// Recent visits are grouped under a month and year. A visit can start in a previous year.
    static func recentVisitDateRange(from startDate: Date, to endDate: Date, locale: Locale = locale) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let includesYear = !calendar.isDate(startDate, equalTo: endDate, toGranularity: .year)
        var style = Date.FormatStyle.dateTime.locale(locale).month().day()
        style.calendar = calendar
        if calendar.isDate(startDate, inSameDayAs: endDate) {
            return startDate.formatted(style)
        }
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.dateTemplate = includesYear ? "yMMMd" : "MMMd"
        return formatter.string(from: startDate, to: endDate)
    }

    static func distance(meters: Double) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitStyle = .medium
        formatter.unitOptions = .naturalScale
        return formatter.string(from: Measurement(value: meters, unit: UnitLength.meters))
    }

    static func dateRange(from startDate: Date, to endDate: Date) -> String {
        guard !Calendar.current.isDate(startDate, inSameDayAs: endDate) else {
            return shortDate(startDate)
        }
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.dateTemplate = "yMMMd"
        return formatter.string(from: startDate, to: endDate)
    }
}
