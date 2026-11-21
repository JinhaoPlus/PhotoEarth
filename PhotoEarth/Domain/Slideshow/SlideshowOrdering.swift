import Foundation

nonisolated enum SlideshowOrdering {
    static func visitComesFirst(_ lhs: TravelPlace, _ rhs: TravelPlace) -> Bool {
        if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
        if lhs.endDate != rhs.endDate { return lhs.endDate < rhs.endDate }
        return lhs.id < rhs.id
    }

    static func recordComesFirst(_ lhs: PhotoAssetRecord, _ rhs: PhotoAssetRecord) -> Bool {
        lhs.creationDate == rhs.creationDate ? lhs.id < rhs.id : lhs.creationDate < rhs.creationDate
    }
}
