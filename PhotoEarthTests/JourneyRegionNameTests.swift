import Foundation
import Testing
@testable import PhotoEarth

struct JourneyRegionNameTests {
    @Test func namedTerritoriesKeepTheirIdentityAcrossCatalogsAndChineseRegions() {
        for (language, somaliland, cyprus) in [
            ("en", "Somaliland", "Northern Cyprus"), ("de", "Somaliland", "Nordzypern"),
            ("fr", "Somaliland", "Chypre du Nord"), ("es", "Somalilandia", "Chipre del Norte"),
            ("it", "Somaliland", "Cipro del Nord"), ("ja", "ソマリランド", "北キプロス"),
            ("zh-Hans", "索马里兰", "北塞浦路斯"), ("zh-Hant", "索馬利蘭", "北賽普勒斯"),
            ("zh-HK", "索馬里蘭", "北塞浦路斯"), ("zh-MO", "索馬里蘭", "北塞浦路斯"),
            ("zh-TW", "索馬利蘭", "北賽普勒斯"), ("zh-Hans-HK", "索马里兰", "北塞浦路斯")
        ] {
            let locale = Locale(identifier: language)
            #expect(JourneyRegionNames.name(code: "", fallback: "Somaliland", locale: locale) == somaliland)
            #expect(JourneyRegionNames.name(code: "NE:CYN", locale: locale) == cyprus)
            #expect(JourneyRegionNames.name(code: "", fallback: "Kosovo", locale: locale) == locale.localizedString(forRegionCode: "XK"))
            #expect(JourneyRegionNames.name(code: "CY", locale: locale) != cyprus)
        }
    }

    @Test func renamedCountryFollowsCurrentRegionalUsage() {
        let expected = ["en": "Naoero", "de": "Naoero", "es": "Naoero", "fr": "Naoero",
                        "it": "Naoero", "ja": "ナウル", "zh-Hans": "瑙鲁", "zh-Hant": "諾埃羅",
                        "zh-TW": "諾埃羅", "zh-HK": "瑙魯", "zh-MO": "瑙魯"]
        for (language, name) in expected {
            #expect(JourneyRegionNames.name(code: "NR", locale: Locale(identifier: language)) == name)
        }
    }

    @Test func oldVisitsAndNewTranslationsUseTheSameCountryCollectionAndShelfSubtitle() throws {
        let old = TravelPlace(id: "one", name: "Hargeisa", country: "Somaliland",
                              coordinate: .init(latitude: 9.56, longitude: 44.07), startDate: .distantPast,
                              endDate: .distantPast, photoCount: 1, coverAssetID: nil)
        let current = TravelPlace(id: "two", name: "Hargeisa", country: "索馬利蘭", regionCode: "NE:SOL",
                              coordinate: old.coordinate, startDate: .distantPast, endDate: .now,
                              photoCount: 1, coverAssetID: nil)
        let group = try #require(PlaceCollection.countries([old, current]).first)
        #expect(group.id == "country:name:Somaliland")
        #expect(Set(try group.matchingPlaceIDs(in: [current, old])) == ["one", "two"])
        let legacy = JourneyShelfItem(route: "old", title: "A", assetID: "1", photoProof: "1", period: "Somaliland")
        var newer = JourneyShelfItem(route: "new", title: "A", assetID: "2", photoProof: "2")
        newer.regionCode = "NE:CYN"
        let titles = JourneyShelfItem.displayTitles(in: [legacy, newer], language: "ja")
        #expect(titles == ["old": "A ソマリランド", "new": "A 北キプロス"])
    }
}
