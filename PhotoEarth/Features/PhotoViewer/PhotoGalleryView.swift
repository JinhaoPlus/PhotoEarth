import SwiftUI

struct PhotoGalleryView: View {
    let place: TravelPlace
    let assetIDs: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var selectedAssetID: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 28), count: 4)

    var body: some View {
        ZStack {
            Color(red: 0.006, green: 0.012, blue: 0.03).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(place.country?.uppercased() ?? "TRAVEL MEMORY")
                                .font(.caption.bold())
                                .tracking(5)
                                .foregroundStyle(.cyan)
                            Text(place.name)
                                .font(.system(size: 58, weight: .bold, design: .rounded))
                            Text("\(place.dateRangeText)  ·  \(place.photoCount) 张照片")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("返回地球", systemImage: "globe.asia.australia", action: dismiss.callAsFunction)
                            .buttonStyle(.bordered)
                    }

                    LazyVGrid(columns: columns, spacing: 28) {
                        ForEach(assetIDs, id: \.self) { assetID in
                            Button {
                                selectedAssetID = assetID
                            } label: {
                                PhotoAssetImage(assetID: assetID)
                                    .frame(height: 235)
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .stroke(.white.opacity(0.1), lineWidth: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 55)
            }

            if let selectedAssetID {
                ZStack(alignment: .topTrailing) {
                    Color.black.opacity(0.94).ignoresSafeArea()
                    PhotoAssetImage(assetID: selectedAssetID, contentMode: .fit)
                        .padding(70)
                    Button {
                        self.selectedAssetID = nil
                    } label: {
                        Label("关闭照片", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .padding(55)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: selectedAssetID)
    }
}
