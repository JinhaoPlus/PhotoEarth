import SwiftUI
import UIKit

struct PhotoAssetImage: View {
    let assetID: String
    var contentMode: ContentMode = .fill
    var targetSize = CGSize(width: 1_000, height: 700)

    @StateObject private var loader = PhotoImageLoader()

    var body: some View {
        Group {
            if assetID == "sample-reykjavik-1" {
                if let url = Bundle.main.url(forResource: "SampleIceland", withExtension: "png"),
                   let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else {
                    SamplePhotoArtwork(seed: assetID)
                }
            } else if assetID.hasPrefix("sample-") {
                SamplePhotoArtwork(seed: assetID)
            } else if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                ZStack {
                    Color.white.opacity(0.06)
                    if loader.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }
        }
        .clipped()
        .task(id: assetID) {
            loader.load(assetID: assetID, targetSize: targetSize)
        }
        .onDisappear { loader.cancel() }
    }
}

struct SamplePhotoArtwork: View {
    let seed: String

    private var palette: [Color] {
        let value = seed.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let palettes: [[Color]] = [
            [.indigo, .cyan, .mint],
            [.orange, .pink, .purple],
            [.blue, .teal, .yellow],
            [.purple, .blue, .black],
            [.red, .orange, .yellow],
        ]
        return palettes[value % palettes.count]
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle()
                    .fill(.white.opacity(0.17))
                    .frame(width: proxy.size.width * 0.48)
                    .blur(radius: 8)
                    .offset(x: proxy.size.width * 0.24, y: -proxy.size.height * 0.18)
                WaveShape()
                    .fill(.black.opacity(0.28))
                    .frame(height: proxy.size.height * 0.46)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

private struct WaveShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.height * 0.58))
        path.addCurve(
            to: CGPoint(x: rect.width, y: rect.height * 0.25),
            control1: CGPoint(x: rect.width * 0.28, y: -rect.height * 0.08),
            control2: CGPoint(x: rect.width * 0.65, y: rect.height * 0.95)
        )
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}
