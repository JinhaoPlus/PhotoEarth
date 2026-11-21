import Foundation
import Testing
@testable import PhotoEarth

@objcMembers private final class LibraryAddressProperties: NSObject {
    let reverseLocationDataIsValid: NSNumber
    let addressString: Any

    init(valid: Bool, address: Any) {
        reverseLocationDataIsValid = NSNumber(value: valid)
        addressString = address
    }
}

struct PhotoDetailAddressTests {
    @Test func displaysOnlyValidNonemptyPhotosTextInItsOriginalLanguage() {
        let good = LibraryAddressProperties(valid: true, address: "  飛驒高山\n")
        #expect(PECachedPhotoAddress.validatedText(from: good) == "飛驒高山")
        for malformed in [
            LibraryAddressProperties(valid: false, address: "Old address"),
            LibraryAddressProperties(valid: true, address: " \n"),
            LibraryAddressProperties(valid: true, address: NSNumber(value: 7)),
            LibraryAddressProperties(valid: true, address: String(repeating: "x", count: 4097))
        ] {
            #expect(PECachedPhotoAddress.validatedText(from: malformed) == nil)
        }
        #expect(PECachedPhotoAddress.validatedText(from: NSObject()) == nil)
    }
}


import Photos

extension PhotoDetailAddressTests {
    /// Measures what this Photos library actually exposes to the viewer.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTOEARTH_PRIVATE_LIBRARY"] == "1"))
    func readsCachedDetailsFromAuthorizedLibraryAssets() throws {
        try #require(PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized)
        let assets = PHAsset.fetchAssets(with: nil)
        try #require(assets.count > 0)
        var located = 0
        var labeled = 0
        let step = max(1, assets.count / 200)
        for i in stride(from: 0, to: assets.count, by: step) {
            autoreleasepool {
                let item = assets.object(at: i)
                guard let coordinate = item.location?.coordinate else { return }
                located += 1
                if let label = PECachedPhotoAddress.read(identifier: item.localIdentifier,
                                                         latitude: coordinate.latitude, longitude: coordinate.longitude) {
                    #expect(!label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    labeled += 1
                }
            }
        }
        #expect(located > 0)
        print("PHOTO_EARTH_CACHE_PROBE located=\(located) cachedAddresses=\(labeled)")
    }
}
