import SwiftUI

extension PlaceDisplayLabel {
    func styledName(citySize: CGFloat) -> AttributedString {
        var title = AttributedString(displayCity)
        if let country = countryAfterCity {
            var suffix = AttributedString(" \(country)")
            suffix.font = .system(size: (citySize * 0.76).rounded(), weight: .regular)
            suffix.foregroundColor = Color(white: 0.73)
            title.append(suffix)
        }
        return title
    }
}

/// The arrival row uses the proportions of a tvOS Home Screen icon.
/// City shelves below the fold retain their square covers.
struct PlaceCard: View {
    let place: TravelPlace
    let isSelected: Bool
    var isFocused = false
    var displayLabel: PlaceDisplayLabel? = nil
    var latestAssetID: String? = nil
    var cardWidth: CGFloat = 312
    var isArrival = false
    var loadsImage = true
    var usesManagedThumbnail = false
    var thumbnail: OverviewThumbnail?
    var waitingForSelection = false
    var coverUnavailable = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var label: PlaceDisplayLabel {
        displayLabel ?? PlaceDisplayLabel(place: place)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                photo
                    .frame(width: cardWidth, height: coverHeight)
                    .clipped()
                caption
                    .padding(.horizontal, isArrival ? 14 : 18)
                    .padding(.vertical, isArrival ? 9 : 16)
            }
            .frame(width: cardWidth)
            .contentShape(Rectangle())
            .foregroundStyle(.white)
            .background(.black.opacity(backgroundOpacity))
            .clipShape(RoundedRectangle(cornerRadius: isArrival ? 18 : 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: isArrival ? 18 : 22, style: .continuous)
                    .strokeBorder(
                        .white.opacity(isFocused ? 0.92 : (isSelected ? 0.56 : 0.10)),
                        lineWidth: isFocused ? 2 : 0.75
                    )
            }
            .shadow(color: .black.opacity(isFocused ? 0.4 : 0.16), radius: isFocused ? 16 : 6, y: 6)
            .scaleEffect(isFocused && !reduceMotion ? 1.025 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isFocused)
        }
        .buttonStyle(QuietPhotoButtonStyle())
        .focusEffectDisabled()
        .accessibilityLabel(AppLocalization.format(
            "place_card.accessibility",
            defaultValue: "%1$@, %2$@ on your most recent visit",
            label.compactName,
            AppLocalization.itemCount(place.photoCount)
        ))
        .accessibilityHint(AppLocalization.string("place_card.hint", defaultValue: "Start exploring the globe from this place"))
    }

    private var coverHeight: CGFloat {
        if isArrival { return cardWidth * 3 / 5 }
        return usesManagedThumbnail ? cardWidth : cardWidth * 0.56
    }

    private var backgroundOpacity: Double {
        if reduceTransparency { return 1 }
        if isFocused { return 0.65 }
        return isArrival ? 0.55 : 0.24
    }

    private var photo: some View {
        ZStack(alignment: .topTrailing) {
            if usesManagedThumbnail {
                OverviewThumbnailView(thumbnail: thumbnail, isArrival: isArrival, isFocused: isFocused, waitingForSelection: waitingForSelection, coverUnavailable: coverUnavailable)
            } else if loadsImage, let assetID = latestAssetID ?? place.coverAssetID {
                PhotoAssetImage(assetID: assetID, targetSize: isArrival ? CGSize(width: 640, height: 384) : CGSize(width: 640, height: 400))
            } else {
                Rectangle()
                    .fill(.white.opacity(0.08))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.white.opacity(0.55))
                    }
            }
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 25, weight: .medium))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.black, .white)
                    .padding(10)
            }
        }
        .transaction { $0.animation = nil }
    }

    private var caption: some View {
        Text(label.styledName(citySize: 27))
            .font(.system(size: 27, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OverviewThumbnailView: View {
    let thumbnail: OverviewThumbnail?
    let isArrival: Bool
    let isFocused: Bool
    let waitingForSelection: Bool
    let coverUnavailable: Bool

    private var phase: CoverDisplayPhase {
        if thumbnail?.image != nil { return .displayed }
        if coverUnavailable || thumbnail?.status == .unavailable { return .idle }
        return waitingForSelection || thumbnail != nil ? .waiting : .idle
    }
    var body: some View {
        // The fixed surface owns layout. A wide aspect-fill image must not
        // change the button's preferred size or the native scroll focus frame.
        Rectangle().fill(.white.opacity(0.08))
            .overlay {
                if let image = thumbnail?.image {
                    GeometryReader { geometry in
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                } else {
                    if phase == .idle { WaitingCoverView(usesGlassBackground: !isArrival) }
                    if !isArrival, isFocused, phase == .idle, coverUnavailable || thumbnail?.status == .unavailable {
                        Label(AppLocalization.string("photo.preview_unavailable", defaultValue: "Photo not loaded"), systemImage: "photo")
                            .font(.system(size: 18))
                    }
                }
            }
            .overlay { CoverLoadingOverlay(phase: phase, focused: isFocused, usesGlassBackground: !isArrival) }
            .clipped()
            .accessibilityHidden(true)
    }
}

struct WaitingCoverView: View {
    var usesGlassBackground = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            Image(uiImage: CoverWaitingArtwork.image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .opacity(reduceTransparency ? 1 : 0.72)
                .background {
                    if !reduceTransparency && usesGlassBackground {
                        Color.clear.glassEffect(.clear, in: Rectangle())
                    }
                }
        }
        .accessibilityHidden(true)
    }
}
