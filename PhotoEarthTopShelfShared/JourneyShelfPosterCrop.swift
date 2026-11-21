import CoreGraphics

nonisolated enum JourneyShelfPosterCrop {
    static let aspectRatio: CGFloat = 2.0 / 3.0

    static func sourceRect(in size: CGSize) -> CGRect {
        let width = min(size.width, size.height * aspectRatio)
        let height = min(size.height, size.width / aspectRatio)
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                      width: width, height: height)
    }
}
