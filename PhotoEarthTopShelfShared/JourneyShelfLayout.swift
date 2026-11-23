import Foundation
import TVServices

nonisolated enum JourneyShelfLayout {
    static func content(globeTitle: String, globeImage: URL?, journeys: [TVTopShelfSectionedItem],
                        readablePosterRoutes: Set<String>) -> TVTopShelfSectionedContent? {
        let recent = journeys.prefix(JourneyShelfSnapshot.limit)
        guard recent.contains(where: { readablePosterRoutes.contains($0.identifier) }) else { return nil }
        let globe = TVTopShelfSectionedItem(identifier: "photoearth.globe")
        globe.title = globeTitle
        globe.imageShape = .hdtv
        globe.displayAction = TVTopShelfAction(url: JourneyShelfDestination.globeURL)
        globe.setImageURL(globeImage, for: .screenScale1x)
        globe.setImageURL(globeImage, for: .screenScale2x)
        for item in recent { item.imageShape = .poster }
        let section = TVTopShelfItemCollection(items: [globe] + recent)
        section.title = "PHOTO EARTH"
        return TVTopShelfSectionedContent(sections: [section])
    }
}
