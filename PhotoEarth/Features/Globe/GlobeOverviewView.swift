import SwiftUI

struct GlobeOverviewView: View {
    let places: [TravelPlace]
    let labels: [String: PlaceDisplayLabel]
    let latestAssetIDs: [String: String]
    let hasMorePlaces: Bool
    let hasUserLocation: Bool
    let isAwaitingUserLocation: Bool
    let isUsingSampleData: Bool
    let photoCount: Int
    let enterGlobe: () -> Void
    let openPlace: (TravelPlace) -> Void
    let loadMorePlaces: () -> Void

    @FocusState private var focusedID: String?

    private let placesPerShelf = 5

    private var recentPlaces: [TravelPlace] {
        Array(places.prefix(placesPerShelf))
    }

    private var additionalShelves: [PlaceShelf] {
        let remaining = Array(places.dropFirst(recentPlaces.count))
        guard !remaining.isEmpty else { return [] }

        var shelves: [PlaceShelf] = []
        for (shelfIndex, start) in stride(
            from: 0,
            to: remaining.count,
            by: placesPerShelf
        ).enumerated() {
            let end = min(start + placesPerShelf, remaining.count)
            let shelfPlaces = Array(remaining[start..<end])
            let years = Set(shelfPlaces.map { Calendar.current.component(.year, from: $0.endDate) })
            let title = years.count == 1
                ? "\(years.first ?? 0) 年的足迹"
                : "更多城市与国家"
            shelves.append(
                PlaceShelf(
                    id: "places-shelf-\(shelfIndex)",
                    title: title,
                    subtitle: "\(shelfPlaces.count) 个地点",
                    places: shelfPlaces
                )
            )
        }
        return shelves
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 46) {
                header
                    .padding(.horizontal, 66)
                    .padding(.top, 38)

                hero
                    .padding(.horizontal, 66)
                    .frame(minHeight: 290, alignment: .bottomLeading)

                recentDock

                if !additionalShelves.isEmpty {
                    morePlacesHeader

                    ForEach(additionalShelves) { shelf in
                        placeShelf(shelf)
                    }
                }

                if hasMorePlaces {
                    ProgressView("正在展开更多足迹…")
                        .tint(.cyan)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 50)
                } else if places.count > placesPerShelf {
                    Text("你走过的地方，都在这里")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.28))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                }
            }
            .padding(.bottom, 40)
        }
        .foregroundStyle(.white)
        .background(overviewMask)
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                focusedID = "enter-globe"
            }
        }
        .accessibilityIdentifier("globe-overview")
    }

    private var header: some View {
        HStack {
            HStack(spacing: 14) {
                Circle()
                    .fill(.cyan)
                    .frame(width: 8, height: 8)
                    .shadow(color: .cyan, radius: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PHOTO EARTH")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .tracking(4)
                    Text("A PRIVATE ATLAS OF MEMORY")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(2.7)
                        .foregroundStyle(.cyan.opacity(0.72))
                }
            }

            Spacer()

            Button(action: enterGlobe) {
                HStack(spacing: 14) {
                    Image(systemName: "move.3d")
                        .font(.system(size: 21, weight: .semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("滚动地球")
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                        Text("用遥控器把玩你的世界")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.cyan)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 15)
            }
            .buttonStyle(.glassProminent)
            .tint(.cyan.opacity(0.28))
            .focused($focusedID, equals: "enter-globe")
            .accessibilityIdentifier("enter-globe-control")
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("YOUR WORLD, REMEMBERED")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .tracking(5)
                .foregroundStyle(.cyan.opacity(0.84))
            Text("从你所在的地方，\n重新看见走过的世界")
                .font(.system(size: 45, weight: .semibold, design: .rounded))
                .tracking(-1.2)
                .lineSpacing(3)
            HStack(spacing: 12) {
                Circle()
                    .fill(hasUserLocation ? .cyan : .white.opacity(0.42))
                    .frame(width: 7, height: 7)
                    .shadow(color: hasUserLocation ? .cyan : .clear, radius: 7)
                Text(locationText)
                Text("·")
                    .foregroundStyle(.white.opacity(0.28))
                Text("\(photoCount) 张地理记忆")
                    .monospacedDigit()
            }
            .font(.system(size: 16, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.56))
        }
    }

    private var recentDock: some View {
        VStack(alignment: .leading, spacing: 16) {
            shelfHeader(
                title: "最近抵达",
                eyebrow: "RECENT PLACES",
                trailing: "选择地点，或从那里开始滚动"
            )
            .padding(.horizontal, 30)

            GlassEffectContainer(spacing: 28) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 34) {
                        ForEach(recentPlaces) { place in
                            placeCard(place)
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.vertical, 27)
                }
                .scrollClipDisabled()
                .glassEffect(
                    .regular.tint(.black.opacity(0.24)),
                    in: RoundedRectangle(cornerRadius: 34, style: .continuous)
                )
            }
        }
        .padding(.horizontal, 66)
        .focusSection()
        .accessibilityIdentifier("recent-places-dock")
    }

    private var morePlacesHeader: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 7) {
                Text("更多城市与国家")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("继续向下，沿着时间翻阅你的世界")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.44))
            }
            Spacer()
            Image(systemName: "chevron.down")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.cyan.opacity(0.65))
        }
        .padding(.horizontal, 66)
        .padding(.top, 14)
    }

    private func placeShelf(_ shelf: PlaceShelf) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            shelfHeader(
                title: shelf.title,
                eyebrow: "TRAVEL SHELF",
                trailing: shelf.subtitle
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 34) {
                    ForEach(shelf.places) { place in
                        placeCard(place)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 23)
            }
            .scrollClipDisabled()
        }
        .padding(.horizontal, 66)
        .focusSection()
        .accessibilityIdentifier(shelf.id)
    }

    private func shelfHeader(title: String, eyebrow: String, trailing: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
            Text(eyebrow)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(3.2)
                .foregroundStyle(.cyan.opacity(0.64))
            Spacer()
            Text(trailing)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))
        }
    }

    private func placeCard(_ place: TravelPlace) -> some View {
        let label = labels[place.id] ?? PlaceDisplayLabel(place: place)
        let assetID = latestAssetIDs[place.id] ?? place.coverAssetID
        let focusID = "place-\(place.id)"
        let isFocused = focusedID == focusID

        return Button { openPlace(place) } label: {
            ZStack(alignment: .bottomLeading) {
                if let assetID {
                    PhotoAssetImage(
                        assetID: assetID,
                        targetSize: CGSize(width: 680, height: 400)
                    )
                } else {
                    Color.white.opacity(0.06)
                }

                LinearGradient(
                    colors: [.white.opacity(0.05), .clear, .black.opacity(0.88)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(label.country?.uppercased() ?? "TRAVEL MEMORY")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(2.4)
                        .foregroundStyle(.cyan.opacity(0.9))
                    Text(label.city)
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text("\(place.photoCount) 张 · \(place.dateRangeText)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.64))
                        .lineLimit(1)
                }
                .padding(17)
            }
            .frame(width: 286, height: 174)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        isFocused ? .cyan.opacity(0.48) : .white.opacity(0.12),
                        lineWidth: isFocused ? 1.5 : 1
                    )
            }
            .shadow(
                color: isFocused ? .cyan.opacity(0.28) : .black.opacity(0.22),
                radius: isFocused ? 22 : 8,
                y: isFocused ? 8 : 4
            )
            .scaleEffect(isFocused ? 1.035 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isFocused)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($focusedID, equals: focusID)
        .zIndex(isFocused ? 2 : 0)
        .accessibilityLabel("\(label.city)，\(label.country ?? "旅行地点")")
        .accessibilityIdentifier("place-card-\(place.id)")
        .onMoveCommand { direction in
            moveFocusVertically(from: place, direction: direction)
        }
        .onChange(of: isFocused) { _, focused in
            guard focused,
                  hasMorePlaces,
                  places.suffix(placesPerShelf).contains(where: { $0.id == place.id }) else {
                return
            }
            loadMorePlaces()
        }
    }

    private func moveFocusVertically(
        from place: TravelPlace,
        direction: MoveCommandDirection
    ) {
        guard let index = places.firstIndex(where: { $0.id == place.id }) else { return }
        switch direction {
        case .left:
            guard index % placesPerShelf > 0 else { return }
            focusedID = "place-\(places[index - 1].id)"
        case .right:
            let targetIndex = index + 1
            guard targetIndex < places.count,
                  targetIndex / placesPerShelf == index / placesPerShelf else { return }
            focusedID = "place-\(places[targetIndex].id)"
        case .down:
            let targetIndex = index + placesPerShelf
            guard targetIndex < places.count else { return }
            focusedID = "place-\(places[targetIndex].id)"
        case .up:
            let targetIndex = index - placesPerShelf
            if targetIndex >= 0 {
                focusedID = "place-\(places[targetIndex].id)"
            } else {
                focusedID = "enter-globe"
            }
        default:
            break
        }
    }

    private var overviewMask: some View {
        LinearGradient(
            colors: [.black.opacity(0.12), .black.opacity(0.38), .black.opacity(0.92)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var locationText: String {
        if hasUserLocation { return "已锚定你所在的区域" }
        if isUsingSampleData { return "示例从最近旅行地展开" }
        return isAwaitingUserLocation ? "正在确定你所在的区域" : "已从最近旅行地展开"
    }
}

private struct PlaceShelf: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let places: [TravelPlace]
}
