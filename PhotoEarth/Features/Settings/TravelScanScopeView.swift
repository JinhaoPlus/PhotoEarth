import SwiftUI

struct TravelScanScopeView: View {
    @ObservedObject var model: AppModel
    let presentation: AppModel.ScanScopePresentation
    @State private var preferences = TravelScanPreferences.load()
    @State private var albums: [ScanAlbum] = []
    @State private var counts: [TravelScanDecision: Int] = [:]
    @State private var fetchedAlbums = false
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var saveFocused: Bool
    @Environment(\.resetFocus) private var resetFocus
    @Namespace private var scopeFocus
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: TVControlLayout.actionSpacing) {
                Text(AppLocalization.string("scan.scope.title", defaultValue: "Albums to Exclude from Scanning")).font(.title2)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if saveTask != nil { ProgressView() }
                Button(presentation.startsFirstScan ? AppLocalization.string("scan.scope.start", defaultValue: "Start Scan") : AppLocalization.string("scan.scope.save", defaultValue: "Save Changes"), action: save)
                    .focused($saveFocused)
                    .accessibilityValue(Text(AppLocalization.format("scan.scope.selected_count", defaultValue: "Excluded albums: %@", AppLocalization.number(preferences.excludedAlbums.count))))
                    .accessibilityIdentifier("scan-scope-save")
            }
            Text(AppLocalization.string("scan.scope.subtitle", defaultValue: "Select albums to exclude. Their photos and videos stay hidden even if they also appear in other albums."))
                .font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Toggle(AppLocalization.string("scan.scope.camera", defaultValue: "Exclude media without camera information"), isOn: $preferences.excludesMissingCamera)
                        .accessibilityIdentifier("scan-scope-camera")
                    if preferences.excludesMissingCamera {
                        Text(String(localized: "scan.scope.camera_help"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                        let excluded = preferences.excludedAlbums.contains(album.id)
                        Button {
                            if excluded { preferences.excludedAlbums.remove(album.id) }
                            else { preferences.excludedAlbums.insert(album.id) }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: excluded ? "checkmark.circle.fill" : "circle")
                                Text(album.title).lineLimit(2)
                                Spacer()
                                Text(AppLocalization.number(album.count)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                            }
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityAddTraits(excluded ? .isSelected : [])
                        .accessibilityLabel(Text(album.title))
                        .accessibilityValue(Text(AppLocalization.number(album.count)))
                        .accessibilityIdentifier("scan-scope-album-\(index)")
                    }
                    if fetchedAlbums {
                        let unreadable = preferences.excludedAlbums.subtracting(albums.map(\.id)).sorted()
                        ForEach(Array(unreadable.enumerated()), id: \.element) { index, id in
                            Toggle(isOn: Binding(get: { preferences.excludedAlbums.contains(id) }, set: { enabled in
                                if !enabled { preferences.excludedAlbums.remove(id) }
                            })) {
                                Text(AppLocalization.string("scan.count.unavailable", defaultValue: "Unavailable") + " · " + AppLocalization.number(index + 1))
                            }
                        }
                    }
                    if !counts.isEmpty {
                        ForEach(TravelScanDecision.allCases, id: \.rawValue) { reason in
                            if let count = counts[reason], count > 0 {
                                HStack { Text(reason.displayName); Spacer(); Text(AppLocalization.number(count)) }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityIdentifier("scan-count-\(reason.rawValue)")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .disabled(saveTask != nil)
        }
        .defaultFocus($saveFocused, true, priority: .userInitiated)
        .focusScope(scopeFocus)
        .task {
            await Task.yield()
            resetFocus(in: scopeFocus)
            saveFocused = true
        }
        .padding(56)
        .frame(width: 1240, height: 840)
        .onExitCommand {
            saveTask?.cancel()
            model.cancelScanScope()
        }
        .onDisappear { saveTask?.cancel() }
        .task {
            do {
                albums = try await Task.detached(priority: .utility) { try TravelScanScope.albums() }.value
                fetchedAlbums = true
            }
            catch { failure = AppLocalization.string("scan.scope.unavailable", defaultValue: "Couldn’t load your albums. Close this screen and reopen it to try again.") }
            while !Task.isCancelled {
                counts = await model.scanCounts()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func save() {
        guard saveTask == nil else { return }
        let draft = preferences
        failure = nil
        saveTask = Task {
            defer { saveTask = nil }
            do { try await model.acceptScanScope(draft, presentation: presentation) }
            catch is CancellationError { return }
            catch { failure = AppLocalization.string("scan.scope.apply_failed", defaultValue: "Couldn’t apply your scan settings. Try again.") }
        }
    }
}

private extension TravelScanDecision {
    var displayName: String {
        switch self {
        case .eligible: AppLocalization.string("scan.count.included", defaultValue: "Included")
        case .unavailable: AppLocalization.string("scan.count.unavailable", defaultValue: "Unavailable")
        case .excludedAlbum: AppLocalization.string("scan.count.album", defaultValue: "In excluded albums")
        case .screenCapture: AppLocalization.string("scan.count.screen", defaultValue: "Screenshots and screen recordings")
        case .invalidDate: AppLocalization.string("scan.count.date", defaultValue: "Missing capture date")
        case .missingLocation: AppLocalization.string("scan.count.location", defaultValue: "Missing location")
        case .noCamera: AppLocalization.string("scan.count.camera", defaultValue: "Confirmed missing camera information")
        case .pendingCamera: AppLocalization.string("scan.count.pending", defaultValue: "Included · camera details unverified")
        }
    }
}
