import Foundation

/// Natural Earth's ADM0_A3 identifiers are namespaced to distinguish them from ISO region codes.
/// Catalogs with an empty ISO field historically stored the English territory name.
nonisolated enum JourneyRegionNames {
    static func identifier(code: String?, fallback: String?) -> String? {
        if let code, !code.isEmpty { return code.uppercased() }
        switch fallback {
        case "Somaliland": return "NE:SOL"
        case "Northern Cyprus": return "NE:CYN"
        case "Kosovo": return "XK"
        default: return nil
        }
    }

    static func name(code: String?, fallback: String? = nil, locale: Locale) -> String? {
        guard let code = identifier(code: code, fallback: fallback) else { return fallback }
        let language = locale.language.languageCode?.identifier
        switch code {
        case "NE:SOL":
            switch language {
            case "es": return "Somalilandia"
            case "ja": return "ソマリランド"
            case "zh":
                if locale.language.script?.identifier != "Hant" { return "索马里兰" }
                return ["HK", "MO"].contains(locale.region?.identifier) ? "索馬里蘭" : "索馬利蘭"
            default: return "Somaliland"
            }
        case "NE:CYN":
            switch language {
            case "de": return "Nordzypern"
            case "es": return "Chipre del Norte"
            case "fr": return "Chypre du Nord"
            case "it": return "Cipro del Nord"
            case "ja": return "北キプロス"
            case "zh":
                if locale.language.script?.identifier == "Hant", !["HK", "MO"].contains(locale.region?.identifier) {
                    return "北賽普勒斯"
                }
                return "北塞浦路斯"
            default: return "Northern Cyprus"
            }
        case "NR" where ["en", "de", "es", "fr", "it"].contains(language):
            return "Naoero"
        case "NR" where language == "zh" && locale.language.script?.identifier == "Hant"
            && (locale.region == nil || locale.region?.identifier == "TW"):
            return "諾埃羅"
        case "CI" where language == "it": return "Costa d’Avorio"
        case "GS" where language == "en": return "South Georgia & South Sandwich Islands"
        default: return locale.localizedString(forRegionCode: code) ?? fallback
        }
    }
}
