import Foundation

nonisolated enum JourneyShelfImageURL {
    // Both TV screen scales share one representation. Keep a five-item XPC
    // response bounded even if the framework encodes both URLs separately.
    static let byteLimit = 56 * 1024
    static let posterCacheLimit = 48 * 1024
    static let globeByteLimit = 192 * 1024

    static func make(jpeg: Data) -> URL? {
        make(jpeg: jpeg, limit: byteLimit)
    }

    static func globe(jpeg: Data) -> URL? {
        make(jpeg: jpeg, limit: globeByteLimit)
    }

    private static func make(jpeg: Data, limit: Int) -> URL? {
        guard jpeg.count >= 4, jpeg.count <= limit,
              jpeg.starts(with: [0xff, 0xd8]), jpeg.suffix(2).elementsEqual([0xff, 0xd9]) else { return nil }
        return URL(string: "data:image/jpeg;base64," + jpeg.base64EncodedString())
    }
}
