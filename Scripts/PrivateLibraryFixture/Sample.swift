import Foundation

// Only the private fixture directory contains source dates, GPS and membership.
struct SampleItem: Codable {
    let key: String
    let date: Date
    let latitude: Double?
    let longitude: Double?
    let favorite: Bool
    let kind: String
    let screenshot: Bool
    let recording: Bool
    let files: [String]
    var albums: [Int]
}
