import SwiftUI

/// Keep the current scale available to VoiceOver without making the overview
/// shelves observe every camera frame.
struct GlobeCameraAccessibility: ViewModifier {
    @ObservedObject var experience: GlobeExperienceModel

    func body(content: Content) -> some View {
        content.accessibilityValue(AppLocalization.format("globe.camera_distance", defaultValue: "Camera distance %@", AppLocalization.distance(meters: experience.displayedCamera.distance)))
    }
}

/// Read capability alongside the small camera subtree, rather than making the
/// entire overview and its image shelves observe remote connection changes.
struct GlobeInputAccessibility: ViewModifier {
    @ObservedObject var experience: GlobeExperienceModel

    func body(content: Content) -> some View {
        content
            .accessibilityLabel(AppLocalization.string("home.explore_globe", defaultValue: "Explore the Globe"))
            .accessibilityHint(AppLocalization.globeInputHint(supportsTouchPan: experience.supportsTouchPan))
    }
}

/// Shared by the globe and photo map. Only the introductory grid times out.
struct MapControlHints: View {
    let guideSymbols: SiriRemoteSymbolNames?
    let supportsTouchPan: Bool
    let dockOpen: Bool
    let prefix: String
    @AppStorage("photoEarth.showsGlobeHints") private var enabled = true

    private var photoHint: String {
        AppLocalization.string("globe.controls.select", defaultValue: "Photos")
    }

    private var zoomActionHint: String {
        AppLocalization.string("globe.controls.zoom", defaultValue: "Zoom")
    }

    private var zoomAccessibilityHint: String {
        AppLocalization.string(
            "globe.controls.zoom_shortcut",
            defaultValue: "Play/Pause · Zoom controls"
        )
    }

    private func operationHint(
        _ title: String,
        systemImage: String,
        accessibilityLabel: String? = nil,
        identifier: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 25, weight: .medium))
                .frame(width: 30)
            Text(title)
                .lineLimit(1)
        }
        .frame(minWidth: guideSymbols == nil ? nil : 124, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityIdentifier(identifier)
    }

    private var panHintID: String { dockOpen ? "\(prefix)-controls-pan-hint" : "\(prefix)-drag-control-hint" }

    private var dragHint: some View {
        operationHint(AppLocalization.string("globe.controls.swipe", defaultValue: "Drag"),
                      systemImage: guideSymbols?.touchSurface ?? "hand.draw", identifier: panHintID)
    }

    var body: some View {
        if enabled && (guideSymbols != nil || supportsTouchPan || dockOpen) {
            Group {
                if let symbols = guideSymbols {
                    Grid(alignment: .leading, horizontalSpacing: 26, verticalSpacing: 12) {
                        GridRow {
                            operationHint(
                                AppLocalization.string("globe.controls.arrows", defaultValue: "Turn"),
                                systemImage: symbols.directionalPad,
                                identifier: "\(prefix)-turn-control-hint"
                            )
                            if supportsTouchPan {
                                dragHint
                            } else {
                                Color.clear.frame(width: 124, height: 30).accessibilityHidden(true)
                            }
                        }
                        GridRow {
                            operationHint(
                                zoomActionHint,
                                systemImage: symbols.playPauseButton,
                                accessibilityLabel: zoomAccessibilityHint,
                                identifier: "\(prefix)-zoom-control-hint"
                            )
                            operationHint(
                                photoHint,
                                systemImage: symbols.centerButton,
                                identifier: "\(prefix)-photo-control-hint"
                            )
                        }
                    }
                } else if supportsTouchPan {
                    dragHint
                } else if dockOpen {
                    operationHint(AppLocalization.string("globe.controls.choose", defaultValue: "Choose"),
                                  systemImage: "arrow.left.and.right", identifier: panHintID)
                }
            }
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
            .floatingSurface(in: RoundedRectangle(cornerRadius: 18))
            .allowsHitTesting(false)
        }
    }
}

/// This small subtree observes motion. The shelves and place dictionaries do not rebuild at 30 Hz.
struct GlobeExploreChrome: View {
    @ObservedObject var experience: GlobeExperienceModel
    let showsControlHint: Bool
    var cityTitle: String? = nil

    private var zoomHint: String? {
        switch experience.zoomBoundary {
        case .regional: AppLocalization.string("globe.zoom.nearest", defaultValue: "Closest view")
        case .global: AppLocalization.string("globe.zoom.farthest", defaultValue: "Farthest view")
        case nil:
            switch experience.zoomDirection {
            case -1: AppLocalization.string("globe.zoom.in", defaultValue: "Zoom In")
            case 1: AppLocalization.string("globe.zoom.out", defaultValue: "Zoom Out")
            default: nil
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                if let cityTitle {
                    Text(AppLocalization.format("globe.scope.city", defaultValue: "%@ · City photos only", cityTitle))
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(.white.opacity(0.94))
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .floatingSurface(in: Capsule())
                        .accessibilityIdentifier("globe-photo-scope")
                }
                Spacer()
                MapControlHints(guideSymbols: showsControlHint ? experience.remoteSymbolNames : nil,
                                supportsTouchPan: experience.supportsTouchPan, dockOpen: false, prefix: "globe")
            }
            .padding(.horizontal, 80)
            .padding(.top, 60)
            Text(zoomHint ?? " ")
                .font(.system(size: 23, weight: .regular))
                .foregroundStyle(Color(red: 0.78, green: 0.86, blue: 0.93).opacity(0.72))
                .padding(.top, 18)
                .opacity(zoomHint == nil ? 0 : 1)
                .accessibilityHidden(zoomHint == nil)
                .accessibilityIdentifier("globe-zoom-hint")
            Spacer()
            MemoryPhotoStrip(
                records: experience.visiblePhotos,
                isReady: experience.photoBatchReady,
                isManipulating: experience.isManipulating,
                isRefreshing: experience.isRefreshingPhotos,
                queryFailed: experience.photoQueryFailed,
                totalPhotoCount: experience.visiblePhotoCount
            )
        }
        .allowsHitTesting(false)
    }
}

struct GlobeControlPanel: View {
    let experience: GlobeExperienceModel
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let close: () -> Void
    var cityTitle: String? = nil
    var useCurrentView: () -> Void = {}

    var body: some View {
        MapZoomControlPanel(zoomIn: zoomIn, zoomOut: zoomOut, close: close,
                            extraTitle: cityTitle == nil ? nil : AppLocalization.string("globe.scope.use_view", defaultValue: "Show Photos in View"),
                            extraSymbol: "viewfinder", extraAction: useCurrentView, experience: experience)
    }
}

/// Shared native Glass Dock and physical-arrow Focus boundary for both maps.
struct MapZoomControlPanel: View {
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let close: () -> Void
    var supportsTouchPan = true
    var extraTitle: String? = nil
    var extraSymbol = "viewfinder"
    var extraAction: () -> Void = {}
    var identifierPrefix = "globe"
    var cameraAccessibilityValue = ""
    var mapStyle: PhotoMapStyle? = nil
    var toggleStyle: () -> Void = {}
    var experience: GlobeExperienceModel? = nil
    @StateObject private var navigation = ZoomButtonFocusNavigation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        ZoomButtonFocusContainer(navigation: navigation) {
            Group {
                if let experience {
                    GlobeZoomControlsContent(experience: experience, navigation: navigation, zoomIn: zoomIn, zoomOut: zoomOut, close: close,
                        extraTitle: extraTitle, extraSymbol: extraSymbol, extraAction: extraAction,
                        reduceMotion: reduceMotion, reduceTransparency: reduceTransparency)
                } else {
                    MapZoomControlPanelContent(
                        navigation: navigation,
                        zoomIn: zoomIn, zoomOut: zoomOut, close: close,
                        status: nil, supportsTouchPan: supportsTouchPan, extraTitle: extraTitle,
                        extraSymbol: extraSymbol, extraAction: extraAction, identifierPrefix: identifierPrefix,
                        mapStyle: mapStyle, toggleStyle: toggleStyle,
                        cameraAccessibilityValue: cameraAccessibilityValue,
                        reduceMotion: reduceMotion, reduceTransparency: reduceTransparency
                    )
                }
            }
            .environment(\.colorScheme, colorScheme)
            .environment(\.locale, locale)
            .environment(\.layoutDirection, layoutDirection)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Observe camera frames inside the native hosting boundary, keeping its
/// outer representable stable during a camera flight.
private struct GlobeZoomControlsContent: View {
    @ObservedObject var experience: GlobeExperienceModel
    let navigation: ZoomButtonFocusNavigation
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let close: () -> Void
    let extraTitle: String?
    let extraSymbol: String
    let extraAction: () -> Void
    let reduceMotion: Bool
    let reduceTransparency: Bool

    private var status: String? {
        switch experience.zoomBoundary {
        case .regional: AppLocalization.string("globe.zoom.nearest", defaultValue: "Closest view")
        case .global: AppLocalization.string("globe.zoom.farthest", defaultValue: "Farthest view")
        case nil: nil
        }
    }
    var body: some View {
        MapZoomControlPanelContent(navigation: navigation, zoomIn: zoomIn, zoomOut: zoomOut, close: close,
            status: status, supportsTouchPan: experience.supportsTouchPan,
            extraTitle: extraTitle, extraSymbol: extraSymbol, extraAction: extraAction, identifierPrefix: "globe",
            mapStyle: experience.mapStyle, toggleStyle: experience.toggleMapStyle,
            cameraAccessibilityValue: AppLocalization.format("globe.camera_distance", defaultValue: "Camera distance %@", AppLocalization.distance(meters: experience.displayedCamera.distance)),
            reduceMotion: reduceMotion, reduceTransparency: reduceTransparency)
    }
}

/// Its FocusState lives inside the hosting boundary, so each explicit physical
/// arrow request resolves to one of the native buttons in this environment.
private struct MapZoomControlPanelContent: View {
    @ObservedObject var navigation: ZoomButtonFocusNavigation
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let close: () -> Void
    let status: String?
    let supportsTouchPan: Bool
    let extraTitle: String?
    let extraSymbol: String
    let extraAction: () -> Void
    let identifierPrefix: String
    let mapStyle: PhotoMapStyle?
    let toggleStyle: () -> Void
    let cameraAccessibilityValue: String
    let reduceMotion: Bool
    let reduceTransparency: Bool
    @FocusState private var focusedControl: ZoomButtonFocusTarget?
    @Namespace private var dockFocusScope
    @Environment(\.resetFocus) private var resetFocus

    var body: some View {
        VStack(spacing: 18) {
            MapControlHints(guideSymbols: nil, supportsTouchPan: supportsTouchPan, dockOpen: true, prefix: identifierPrefix)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 60)
            Spacer()
            if let status {
                Text(status)
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .floatingSurface(in: Capsule())
                    .accessibilityIdentifier("\(identifierPrefix)-controls-status")
            }

            GlassEffectContainer(spacing: TVControlLayout.toolbarSpacing) {
                HStack(spacing: TVControlLayout.toolbarSpacing) {
                    control(AppLocalization.string("globe.zoom.out", defaultValue: "Zoom Out"), symbol: "minus.magnifyingglass", value: .zoomOut,
                            identifier: "\(identifierPrefix)-zoom-out", action: zoomOut)
                    control(AppLocalization.string("globe.zoom.in", defaultValue: "Zoom In"), symbol: "plus.magnifyingglass", value: .zoomIn,
                            identifier: "\(identifierPrefix)-zoom-in", action: zoomIn)

                    if let extraTitle {
                        control(extraTitle, symbol: extraSymbol, value: .currentView,
                                identifier: "globe-use-current-view", action: extraAction)
                    }
                    if let mapStyle {
                        styleSwitch(mapStyle)
                    }
                }
                .padding(10)
                .floatingSurface(in: Capsule())
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("\(identifierPrefix)-zoom-dock")
            }
        }
        .padding(.horizontal, 80)
        // The same full-screen globe stays visible. This floating dock leaves
        // the map's legal attribution at least 88 pt of unobstructed space.
        .padding(.bottom, 104)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .focusSection()
        .focusScope(dockFocusScope)
        .onAppear {
            navigation.includesCurrentView = extraTitle != nil
            navigation.includesMapStyle = mapStyle != nil
            // Native Focus can select the first button before this callback;
            // request the same centered starting action in both map modes.
            focusedControl = .zoomIn
            Task { @MainActor in
                await Task.yield()
                resetFocus(in: dockFocusScope)
            }
        }
        .onChange(of: extraTitle) { _, title in navigation.includesCurrentView = title != nil }
        .onChange(of: mapStyle) { _, style in navigation.includesMapStyle = style != nil }
        .onChange(of: navigation.request) { _, request in focusedControl = request.target }
        .onChange(of: focusedControl) { _, target in navigation.didFocus(target) }
        .onExitCommand(perform: close)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("globe.zoom.accessibility", defaultValue: "Globe zoom controls"))
        .accessibilityHint(supportsTouchPan
            ? AppLocalization.string("globe.zoom.touch_hint", defaultValue: "Swipe on the clickpad or touch surface to drag the globe. Press left or right to choose a zoom control, press the clickpad center or touch surface to activate it, or press Back to close.")
            : AppLocalization.string("globe.zoom.hint", defaultValue: "Press left or right to choose a zoom control, press center to activate it, or press Back to close."))
        .accessibilityIdentifier("\(identifierPrefix)-controls")
        .accessibilityValue(cameraAccessibilityValue)
    }

    /// One native Focus target: physical arrows still navigate the Dock, and
    /// Select slides the selection between the two always-visible map styles.
    private func styleSwitch(_ style: PhotoMapStyle) -> some View {
        let isFocused = focusedControl == .mapStyle
        return Button(action: toggleStyle) {
            TwoOptionControlLabel(secondSelected: style == .standard, focused: isFocused,
                                  minimumSegmentWidth: 96, segmentHeight: 60, horizontalInset: 22) {
                Text(PhotoMapStyle.satellite.title)
            } second: {
                Text(PhotoMapStyle.standard.title)
            }
        }
        .buttonStyle(QuietPhotoButtonStyle())
        .focusEffectDisabled()
        .focused($focusedControl, equals: .mapStyle)
        .accessibilityLabel(style.title)
        .accessibilityValue(style.title)
        .accessibilityHint(AppLocalization.string("review.style.hint", defaultValue: "Switch between map and satellite views"))
        .accessibilityIdentifier("\(identifierPrefix)-style")
    }

    private func control(
        _ title: String, symbol: String, value: ZoomButtonFocusTarget,
        identifier: String, action: @escaping () -> Void
    ) -> some View {
        let isFocused = focusedControl == value
        return Button(action: action) {
            Group {
                if value == .currentView {
                    Label(title, systemImage: symbol)
                        .lineLimit(1)
                        .padding(.horizontal, 26)
                } else {
                    Label(title, systemImage: symbol)
                        .labelStyle(.iconOnly)
                        .frame(width: 72)
                }
            }
            .font(.system(size: 27, weight: .medium))
            .frame(height: 72)
            .foregroundStyle(isFocused ? .black : .white.opacity(0.9))
            .background {
                Capsule().fill(.white.opacity(isFocused ? 0.94 : 0.035))
            }
            .overlay {
                Capsule().strokeBorder(.white.opacity(isFocused ? 0.95 : 0.10), lineWidth: 1)
            }
            .scaleEffect(isFocused && !reduceMotion ? 1.025 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isFocused)
        }
        .buttonStyle(QuietPhotoButtonStyle())
        .prefersDefaultFocus(value == .zoomIn, in: dockFocusScope)
        .focusEffectDisabled()
        .focused($focusedControl, equals: value)
        .accessibilityIdentifier(identifier)
    }
}
