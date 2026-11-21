import Foundation

/// At most five rows around the focused photo, regardless of loaded wall size.
/// Focused place comes first; repeated photos in one cluster share one lookup.
nonisolated enum PhotoPlaceLabelWindow {
    static func placeIDs(in records: [PhotoAssetRecord], focusedPhotoID: String?) -> [String] {
        guard !records.isEmpty else { return [] }
        let focusedIndex = records.firstIndex { $0.id == focusedPhotoID } ?? 0
        let rowStart = focusedIndex / 4 * 4
        let start = max(0, rowStart - 4)
        let end = min(records.count, rowStart + 16)
        let candidates = [records[focusedIndex]] + Array(records[start..<end])
        var seen = Set<String>()
        return Array(candidates.compactMap(\.placeID).filter { seen.insert($0).inserted }.prefix(15))
    }
}

/// Preserve the reader's ordered membership and index its summaries once per wall.
nonisolated struct PhotoWallPlaces {
    let places: [TravelPlace]
    private let byID: [String: Int]

    init(_ places: [TravelPlace] = []) {
        self.places = places
        byID = Dictionary(uniqueKeysWithValues: places.indices.map { (places[$0].id, $0) })
    }

    subscript(id: String) -> TravelPlace? { byID[id].map { places[$0] } }
}
