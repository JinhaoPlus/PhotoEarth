import SwiftUI

struct OnlineTrackArtwork: View {
    let title: String
    let theme: String

    var body: some View {
        Canvas(opaque: true, rendersAsynchronously: true) { context, size in
            if let bitmap = OnlineTrackCover.image(title: title, theme: theme) {
                context.draw(Image(decorative: bitmap, scale: 1), in: CGRect(origin: .zero, size: size))
            }
        }
        .accessibilityHidden(true)
    }
}
