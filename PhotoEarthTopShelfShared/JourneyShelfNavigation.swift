import Foundation

nonisolated enum JourneyShelfDestination: Equatable, Sendable {
    case globe
    case journey(String)

    static let globeURL = URL(string: "photoearth://globe")!

    init?(url: URL, showsJourneys: Bool) {
        if url.absoluteString == Self.globeURL.absoluteString {
            self = .globe
        } else if showsJourneys, let route = JourneyShelfLink.route(url) {
            self = .journey(route)
        } else {
            return nil
        }
    }
}
