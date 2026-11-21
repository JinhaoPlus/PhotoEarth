import CryptoKit
import Foundation
import Security

nonisolated struct JourneyShelfItem: Codable, Equatable, Sendable {
    let route: String
    let title: String
    let assetID: String
    let photoProof: String
    var period: String?
    var endDate: Date?
    var awaitingCover: Bool?

    var localizedTitles: [String: String]?
    var regionCode: String?

    static func displayTitles(in items: [Self], language: String? = nil) -> [String: String] {
        func title(_ item: Self) -> String {
            guard let language, let titles = item.localizedTitles else { return item.title }
            var tag = language
            while true {
                if let match = titles[tag] { return match }
                guard let separator = tag.lastIndex(of: "-") else { return item.title }
                tag = String(tag[..<separator])
            }
        }
        let groups = Dictionary(grouping: items, by: title)
        var titles: [String: String] = [:]
        for item in items {
            let name = title(item)
            let country = language.flatMap {
                JourneyRegionNames.name(code: item.regionCode, fallback: item.period, locale: Locale(identifier: $0))
            }
            if groups[name, default: []].count > 1, let period = country ?? item.period, !period.isEmpty, period != name {
                titles[item.route] = name + " · " + period
            } else {
                titles[item.route] = name
            }
        }
        return titles
    }
}

nonisolated struct JourneyShelfSnapshot: Codable, Equatable, Sendable {
    static let limit = 24
    static let globeMarkerLimit = 5
    static let currentImageVersion = 10
    let sectionTitle: String
    let historyToken: Data
    let limitedAccess: Bool
    var items: [JourneyShelfItem]
    // New display formats must invalidate the system's previously cached URLs.
    var imageVersion: Int?
    var scanScope: String?
    var globePeriod: Int?
    var excludedAlbumMask: Data?
    var catalogRevision: String? = WorldCityAtlas.revision

    static func decodePublication(_ bytes: Data) -> Self? {
        guard bytes.count <= 16_384, let snapshot = try? JSONDecoder().decode(Self.self, from: bytes),
              snapshot.valid, snapshot.catalogRevision == WorldCityAtlas.revision else { return nil }
        return snapshot
    }

    // A compact conservative membership filter. A collision delays a refresh;
    // it cannot expose an item from a changed excluded album.
    static func albumMask(_ ids: Set<String>) -> Data {
        var bytes = Data(repeating: 0, count: 256)
        for id in ids {
            for bit in albumBits(id) { bytes[bit / 8] |= 1 << (bit % 8) }
        }
        return bytes
    }

    private static func albumBits(_ id: String) -> [Int] {
        let digest = Array(SHA256.hash(data: Data(id.utf8)).prefix(6))
        return [0,2,4].map { (Int(digest[$0]) * 256 + Int(digest[$0 + 1])) % 2048 }
    }

    func mayHaveChangedExcludedAlbum(_ updated: Set<String>) -> Bool {
        guard !updated.isEmpty else { return false }
        guard let mask = excludedAlbumMask, mask.count == 256 else { return true }
        return updated.contains { id in Self.albumBits(id).allSatisfy { mask[$0 / 8] & (1 << ($0 % 8)) != 0 } }
    }

    // Only a host that checked the current scan scope can publish a personalized globe.
    // Bind the first five markers to their photo proofs, in camera-anchor order.
    var markerItems: ArraySlice<JourneyShelfItem> { items.prefix(Self.globeMarkerLimit) }

    var globeScope: String? {
        guard valid, imageVersion == Self.currentImageVersion, let scanScope, JourneyShelfLink.isDigest(scanScope) else { return nil }
        return JourneyShelfLink.digest(["native-map-v1", scanScope, String(globePeriod ?? 0), historyToken.base64EncodedString(),
                                        limitedAccess ? "limited" : "full"] + markerItems.flatMap { [$0.route, $0.photoProof] })
    }

    func posterScope(at slot: Int) -> String? {
        guard valid, items.indices.contains(slot), items[slot].awaitingCover != true,
              let scanScope, JourneyShelfLink.isDigest(scanScope) else { return nil }
        return JourneyShelfLink.digest(["poster-from-original-v2", scanScope, historyToken.base64EncodedString(), limitedAccess ? "limited" : "full",
                                        items[slot].route, items[slot].photoProof])
    }

    func eligiblePosters(proofs: [String: String]) -> [(slot: Int, item: JourneyShelfItem)] {
        items.enumerated().compactMap { offset, entry in
            proofs[entry.assetID] == entry.photoProof ? (slot: offset, item: entry) : nil
        }.sorted { lhs, rhs in
            let first = lhs.item.endDate ?? .distantPast
            let second = rhs.item.endDate ?? .distantPast
            return first == second ? lhs.slot < rhs.slot : first > second
        }
    }

    var valid: Bool {
        !sectionTitle.isEmpty && !historyToken.isEmpty && !items.isEmpty && items.count <= Self.limit
            && Set(items.map(\.route)).count == items.count
            && items.allSatisfy { JourneyShelfLink.isDigest($0.route) && !$0.title.isEmpty && !$0.assetID.isEmpty && JourneyShelfLink.isDigest($0.photoProof) }
    }
}

nonisolated enum JourneyShelfLink {
    static func digest(_ parts: [String]) -> String {
        var hash = SHA256()
        for part in parts {
            hash.update(data: Data("\(part.utf8.count):".utf8))
            hash.update(data: Data(part.utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func url(_ route: String) -> URL? {
        guard isDigest(route) else { return nil }
        return URL(string: "photoearth://journey/" + route)
    }

    static func route(_ url: URL) -> String? {
        guard let path = url.pathComponents.last, Self.url(path)?.absoluteString == url.absoluteString else { return nil }
        return path
    }
}

/// The host and its signed extension share the publication and one bounded, scoped MapKit preview.
/// An explicit group is required in both targets, including Debug.
nonisolated enum JourneyShelfKeychain {
    private static func query(account: String = "publication") -> [String: Any]? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PhotoEarthShelfAccessGroup") as? String,
              !group.isEmpty, !group.contains("$") else { return nil }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrAccessGroup as String: group,
                kSecAttrService as String: "PhotoEarth.JourneyShelf.v1", kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false]
    }

    static func read() -> JourneyShelfSnapshot? {
        guard var query = query() else { return nil }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let bytes = result as? Data else { return nil }
        return JourneyShelfSnapshot.decodePublication(bytes)
    }

    static func globe(for scope: String) -> Data? {
        preview(account: "native-map-preview", scope: scope, limit: JourneyShelfImageURL.globeByteLimit)
    }

    static func poster(at slot: Int, in snapshot: JourneyShelfSnapshot) -> Data? {
        snapshot.posterScope(at: slot).flatMap { preview(account: "poster-\(slot)", scope: $0, limit: JourneyShelfImageURL.posterCacheLimit) }
    }

    private static func preview(account: String, scope: String, limit: Int) -> Data? {
        guard JourneyShelfLink.isDigest(scope), var query = query(account: account) else { return nil }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let bytes = result as? Data,
              bytes.count > 64, bytes.count <= limit + 64, bytes.starts(with: scope.utf8) else { return nil }
        return bytes.dropFirst(64)
    }

    @discardableResult static func writeGlobe(_ jpeg: Data?, scope: String? = nil) -> Bool {
        writePreview(jpeg, account: "native-map-preview", scope: scope, limit: JourneyShelfImageURL.globeByteLimit)
    }

    @discardableResult static func writePoster(_ jpeg: Data?, at slot: Int, in snapshot: JourneyShelfSnapshot? = nil) -> Bool {
        guard (0..<JourneyShelfSnapshot.limit).contains(slot) else { return false }
        return writePreview(jpeg, account: "poster-\(slot)", scope: snapshot?.posterScope(at: slot), limit: JourneyShelfImageURL.posterCacheLimit)
    }

    private static func writePreview(_ jpeg: Data?, account: String, scope: String?, limit: Int) -> Bool {
        guard var query = query(account: account) else { return false }
        guard let jpeg else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        guard let scope, JourneyShelfLink.isDigest(scope), jpeg.count <= limit,
              jpeg.starts(with: [0xff, 0xd8]), jpeg.suffix(2).elementsEqual([0xff, 0xd9]) else { return false }
        var bytes = Data(scope.utf8)
        bytes.append(jpeg)
        let attributes = [kSecValueData as String: bytes]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        query[kSecValueData as String] = bytes
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

#if DEBUG
    static func readStatus() -> String {
        guard var query = query() else { return "missingGroupConfiguration" }
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        switch SecItemCopyMatching(query as CFDictionary, nil) {
        case errSecSuccess: return "present"
        case errSecItemNotFound: return "empty"
        case errSecMissingEntitlement: return "missingEntitlement"
        case errSecInteractionNotAllowed: return "locked"
        default: return "unavailable"
        }
    }

    // A diagnostic emitted only by the actual TVServices extension process.
    // The receipt contains aggregate numbers and a timestamp, never an item.
    static func noteProviderResult(_ status: String, count: Int, endDates: [Date], readable: Int) {
        guard var query = query(account: "debug-provider-receipt") else { return }
        let dates = endDates.map { String($0.timeIntervalSince1970) }.joined(separator: ",")
        let bytes = Data("\(Date().timeIntervalSince1970) \(status) \(count) \(readable) \(dates)".utf8)
        let update = [kSecValueData as String: bytes]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            query[kSecValueData as String] = bytes
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func providerReceipt() -> String? {
        guard var query = query(account: "debug-provider-receipt") else { return nil }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let bytes = result as? Data else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
#endif

    @discardableResult static func write(_ value: JourneyShelfSnapshot?) -> Bool {
        guard var query = query() else { return false }
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        guard value.valid, let bytes = try? JSONEncoder().encode(value), bytes.count <= 16_384 else { return false }
        let changes = [kSecValueData as String: bytes]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        query[kSecValueData as String] = bytes
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}

nonisolated struct JourneyShelfGeneration {
    private(set) var current = UUID()

    mutating func advance() -> UUID {
        current = UUID()
        return current
    }

    func accepts(_ ticket: UUID, enabled: Bool, live: Bool, currentRevision: String?, sourceRevision: String) -> Bool {
        ticket == current && enabled && live && currentRevision == sourceRevision
    }
}
