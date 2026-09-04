import SwiftUI

struct PlaceCard: View {
    let place: TravelPlace
    let isSelected: Bool
    var isFocused = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                if let coverID = place.coverAssetID {
                    PhotoAssetImage(assetID: coverID)
                        .frame(width: 76, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(place.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(verbatim: "\(place.year)  ·  \(place.photoCount) 张")
                        .font(.caption)
                        .foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary)
                }
                Spacer(minLength: 8)
                Circle()
                    .fill(isSelected ? Color.orange : Color.cyan.opacity(0.75))
                    .frame(width: isSelected ? 11 : 8, height: isSelected ? 11 : 8)
                    .shadow(color: isSelected ? .orange : .cyan, radius: 7)
            }
            .frame(maxWidth: .infinity)
            .padding(11)
            .background {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(isSelected ? Color.cyan.opacity(0.17) : Color.white.opacity(isFocused ? 0.13 : 0.055))
                    .overlay {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(
                                isSelected ? Color.cyan.opacity(0.7) : Color.white.opacity(isFocused ? 0.5 : 0.08),
                                lineWidth: isFocused ? 2 : 1
                            )
                    }
            }
            .scaleEffect(isFocused ? 1.035 : 1)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .animation(.easeOut(duration: 0.16), value: isFocused)
    }
}
