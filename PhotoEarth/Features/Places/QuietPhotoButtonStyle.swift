import SwiftUI

/// Photo cards own their focus treatment. The system plain style on tvOS 26
/// still adds a light focus plate, which destroys contrast behind white captions.
struct QuietPhotoButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}
