import Foundation

/// Explicit mappings for fictional sample assets, never PhotoKit identifiers.
/// Each city reuses one credited stock photograph across its paging fixtures.
nonisolated enum SamplePhotoResource {
    private struct Resource: Sendable {
        let name: String
        let width: Int
        let height: Int
        var fileExtension = "jpg"
    }

    private static let resources: [String: Resource] = [
        "sample-reykjavik": Resource(name: "DemoReykjavik", width: 1_600, height: 1_200),
        "sample-rio": Resource(name: "DemoRio", width: 1_600, height: 1_067),
        "sample-singapore": Resource(name: "DemoSingapore", width: 1_600, height: 1_067),
        "sample-tokyo": Resource(name: "DemoTokyo", width: 1_600, height: 1_065),
        "sample-sydney": Resource(name: "DemoSydney", width: 1_600, height: 899),
        "sample-cape-town": Resource(name: "DemoCapeTown", width: 1_600, height: 1_067),
        "sample-istanbul": Resource(name: "DemoIstanbul", width: 1_600, height: 1_066),
        "sample-paris": Resource(name: "DemoParis", width: 1_600, height: 1_132),
        "sample-new-york": Resource(name: "DemoNewYork", width: 1_600, height: 1_067),
        "sample-banff": Resource(name: "DemoBanff", width: 1_600, height: 1_067),
    ]
#if DEBUG
    private static let ratioResources: [String: Resource] = [
        "sample-ratio-landscape": Resource(name: "RatioLandscape", width: 1_200, height: 800, fileExtension: "png"),
        "sample-ratio-portrait": Resource(name: "RatioPortrait", width: 800, height: 1_200, fileExtension: "png"),
        "sample-ratio-panorama": Resource(name: "RatioPanorama", width: 2_400, height: 800, fileExtension: "png"),
    ]
#endif

    /// Includes fictional records that intentionally have no bundled resource.
    static func isSample(_ assetID: String) -> Bool {
        assetID.hasPrefix("sample-")
    }

    static func resourceName(for assetID: String) -> String? {
        resource(for: assetID)?.name
    }

    static func url(for assetID: String, bundle: Bundle = .main) -> URL? {
        guard let resource = resource(for: assetID) else { return nil }
        return bundle.url(forResource: resource.name, withExtension: resource.fileExtension)
    }

    static func pixelDimensions(for assetID: String) -> (width: Int, height: Int)? {
        guard let resource = resource(for: assetID) else { return nil }
        return (resource.width, resource.height)
    }

    private static func resource(for assetID: String) -> Resource? {
        guard let separator = assetID.lastIndex(of: "-"),
              let ordinal = Int(assetID[assetID.index(after: separator)...]),
              ordinal > 0 else { return nil }
        let prefix = String(assetID[..<separator])
#if DEBUG
        if prefix == "sample-collage", (1...7).contains(ordinal),
           ProcessInfo.processInfo.arguments.contains(where: { ["--slideshow-collage-fixture", "--slideshow-transition-fixture"].contains($0) }) {
            return Resource(name: "Collage\(ordinal)", width: ordinal <= 3 ? 540 : 720, height: 960)
        }
        if ProcessInfo.processInfo.arguments.contains("--photo-ratio-fixture"), let resource = ratioResources[prefix] { return resource }
#endif
        return resources[prefix]
    }
}
