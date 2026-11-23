import Foundation
import Testing
@testable import PhotoEarth

@Suite(.serialized)
@MainActor
struct LocalizationTests {
    @Test func restoredScanNoticesUseTheCurrentLanguage() throws {
        var progress = LibraryPreparationProgress()
        progress.phase = .complete
        progress.notice = .savedOnDevice
        let data = try JSONEncoder().encode(progress)
        let restored = try JSONDecoder().decode(LibraryPreparationProgress.self, from: data)
        #expect(restored.notice?.text(locale: Locale(identifier: "en")) == "Your scan results are saved on this Apple TV.")
        #expect(restored.notice?.text(locale: Locale(identifier: "zh-Hant")) == "掃描結果已儲存在這部 Apple TV 上。")
        var previous = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        previous.removeValue(forKey: "notice")
        previous["message"] = "Photos and places are saved on this Apple TV."
        let migrated = try JSONDecoder().decode(LibraryPreparationProgress.self, from: JSONSerialization.data(withJSONObject: previous))
        #expect(migrated.phase == .complete && migrated.notice == nil)
    }

    @Test func scanAndSlideshowCountsSelectTheSingularAndPluralForms() {
        let locale = Locale(identifier: "en-US")
        let expectations: [(StaticString, String, String)] = [
            ("preparation.count.remaining", "1 place still needs a name", "2 places still need names"),
            ("preparation.detail.checking", "1 item with location data", "2 items with location data"),
            ("settings.transit_count", "1 item hidden", "2 items hidden"),
            ("slideshow.ready_count", "1 memory ready", "2 memories ready"),
        ]
        for (key, singular, plural) in expectations {
            let format = AppLocalization.string(key, defaultValue: "", locale: locale)
            #expect(String(format: format, locale: locale, arguments: [Int64(1)]) == singular)
            #expect(String(format: format, locale: locale, arguments: [Int64(2)]) == plural)
        }
    }

    @Test func supportedLanguageResolutionDistinguishesChineseScripts() {
        #expect(AppLocalization.language(for: Locale(identifier: "en-GB")) == .english)
        #expect(AppLocalization.language(for: Locale(identifier: "ja-JP")) == .japanese)
        #expect(AppLocalization.language(for: Locale(identifier: "de-DE")) == .german)
        #expect(AppLocalization.language(for: Locale(identifier: "fr-FR")) == .french)
        #expect(AppLocalization.language(for: Locale(identifier: "es-MX")) == .spanish)
        #expect(AppLocalization.language(for: Locale(identifier: "it-IT")) == .italian)
        #expect(AppLocalization.language(for: Locale(identifier: "zh-Hans-CN")) == .simplifiedChinese)
        #expect(AppLocalization.language(for: Locale(identifier: "zh-Hant-TW")) == .traditionalChinese)
        #expect(AppLocalization.language(for: Locale(identifier: "zh-HK")) == .traditionalChinese)
        #expect(AppLocalization.language(for: Locale(identifier: "pt-BR")) == .english)

        let regionalFrench = AppLocalization.supportedLocale(for: Locale(identifier: "fr-CA"))
        #expect(AppLocalization.language(for: regionalFrench) == .french)
        #expect(regionalFrench.region?.identifier == "CA")
    }

    @Test(arguments: [
        ("en", "Adding Place Names"),
        ("zh-Hans", "正在补充地点名称"),
        ("zh-Hant", "正在補充地點名稱"),
    ])
    func preparationStatusPlainlyDescribesPlaceNameWork(localeID: String, expected: String) {
        #expect(AppLocalization.string(
            "preparation.title.labeling",
            defaultValue: "Adding Place Names",
            locale: Locale(identifier: localeID)
        ) == expected)
    }

    @Test func chineseInterfaceCopyUsesNativeProductLanguage() {
        func verify(
            _ key: StaticString,
            simplified: String,
            traditional: String
        ) {
            #expect(AppLocalization.string(
                key,
                defaultValue: "Missing localization",
                locale: Locale(identifier: "zh-Hans")
            ) == simplified)
            #expect(AppLocalization.string(
                key,
                defaultValue: "Missing localization",
                locale: Locale(identifier: "zh-Hant")
            ) == traditional)
        }

        verify("settings.photos_and_scan", simplified: "照片与扫描", traditional: "照片與掃描")
        verify("settings.journeys_on_home", simplified: "显示最近到访的城市", traditional: "顯示最近到訪的城市")
        verify("settings.label_summary", simplified: "已有地名的到访 %1$@ / %2$@", traditional: "已有地名的到訪 %1$@ / %2$@")
        verify("settings.last_organized", simplified: "上次整理：%@", traditional: "上次整理：%@")
        verify("settings.complete_places", simplified: "继续补充地点名称", traditional: "繼續補充地點名稱")
        verify("settings.rebuild", simplified: "重新扫描照片和视频", traditional: "重新掃描照片和影片")
        verify("settings.globe_controls", simplified: "地球操作", traditional: "地球操作")
        verify("state.on", simplified: "已开启", traditional: "已開啟")
        verify("state.off", simplified: "已关闭", traditional: "已關閉")
        verify("ready.title", simplified: "你的旅行地球已准备好", traditional: "你的旅行地球已準備好")
        verify("generation.failed", simplified: "未能生成旅行地球", traditional: "無法建立旅行地球")
        verify("slideshow.failed", simplified: "放映暂不可用", traditional: "放映暫時無法使用")
    }

    @Test(arguments: [
        ("en", "Tokyo", "Japan"),
        ("ja", "東京都", "日本"),
        ("de", "Tokio", "Japan"),
        ("fr", "Tokyo", "Japon"),
        ("es", "Tokio", "Japón"),
        ("it", "Tokyo", "Giappone"),
        ("zh-Hans", "东京", "日本"),
        ("zh-Hant", "東京", "日本"),
    ])
    func offlineTokyoUsesRequestedLocale(localeID: String, city: String, country: String) async throws {
        let label = try JourneyPlaceCatalog.shared.label(
            GeoCoordinate(latitude: 35.686963, longitude: 139.749462),
            locale: Locale(identifier: localeID)
        )
        #expect(label.city == city)
        #expect(label.country == country)
        #expect(label.regionCode == "JP")
        #expect(label.source == JourneyPlaceCatalog.citySource)
        #expect(label.sourceVersion == WorldCityAtlas.revision)
        #expect(label.offlinePlaceID == "catalog:1159151609")
    }

    @Test func visitCaptionsUseTheSectionYearUnlessTheyCrossNewYear() throws {
        let calendar = Calendar.autoupdatingCurrent
        let january = try #require(calendar.date(from: DateComponents(year: 2025, month: 1, day: 5)))
        let february = try #require(calendar.date(from: DateComponents(year: 2025, month: 2, day: 10)))
        let december = try #require(calendar.date(from: DateComponents(year: 2024, month: 12, day: 31)))
        for language in AppLocalization.SupportedLanguage.allCases {
            let locale = Locale(identifier: language.rawValue)
            let oneDay = AppLocalization.recentVisitDateRange(from: january, to: january, locale: locale)
            let twoMonths = AppLocalization.recentVisitDateRange(from: january, to: february, locale: locale)
            let twoYears = AppLocalization.recentVisitDateRange(from: december, to: january, locale: locale)
            #expect(!oneDay.contains("2025") && oneDay.contains("5"))
            #expect(!twoMonths.contains("2025") && twoMonths.contains("5") && twoMonths.contains("10"))
            #expect(twoYears.contains("2024") && twoYears.contains("2025"))
        }
    }

    @Test func compactPlaceCaptionShowsEachKnownNameOnce() {
        #expect(PlaceDisplayLabel(city: "Singapore", country: "Singapore").compactName == "Singapore")
        #expect(PlaceDisplayLabel(city: " Tokyo ", country: "Japan").compactName == "Tokyo Japan")
        #expect(PlaceDisplayLabel(city: "Tokyo", country: nil).compactName == "Tokyo")
        #expect(PlaceDisplayLabel(city: "", country: "Japan").compactName == AppLocalization.unknownPlace(near: "Japan"))
    }

    @Test func pluralCatalogUsesLanguageRules() {
        #expect(AppLocalization.itemCount(1, locale: Locale(identifier: "en")) == "1 item")
        #expect(AppLocalization.itemCount(2, locale: Locale(identifier: "en")) == "2 items")
        #expect(AppLocalization.itemCount(2, locale: Locale(identifier: "zh-Hans")) == "2 项")
        #expect(AppLocalization.itemCount(2, locale: Locale(identifier: "zh-Hant")) == "2 項")
        #expect(AppLocalization.photoCount(1, locale: Locale(identifier: "en")) == "1 photo")
        #expect(AppLocalization.photoCount(2, locale: Locale(identifier: "en")) == "2 photos")
        #expect(AppLocalization.visitCount(1, locale: Locale(identifier: "en")) == "1 visit")
        #expect(AppLocalization.visitCount(2, locale: Locale(identifier: "en")) == "2 visits")
        #expect(AppLocalization.visitCount(2, locale: Locale(identifier: "zh-Hans")) == "2 次到访")
        #expect(AppLocalization.placeCount(2, locale: Locale(identifier: "de")) == "2 Orte")
        #expect(AppLocalization.cityCount(2, locale: Locale(identifier: "ja")) == "2都市")
        #expect(AppLocalization.photoCount(2, locale: Locale(identifier: "zh-Hans")) == "2 张照片")
        #expect(AppLocalization.photoCount(2, locale: Locale(identifier: "zh-Hant")) == "2 張照片")
    }

    @Test(arguments: [
        ("en", "Drag", "Turn", "Photos", "Zoom", "Play/Pause · Zoom controls"),
        ("de", "Ziehen", "Drehen", "Fotos", "Zoom", "Wiedergabe/Pause · Zoomsteuerung"),
        ("es", "Arrastrar", "Girar", "Fotos", "Zoom", "Reproducir/Pausa · Controles de zoom"),
        ("fr", "Déplacer", "Tourner", "Photos", "Zoom", "Lecture/Pause · Commandes de zoom"),
        ("it", "Trascina", "Ruota", "Foto", "Zoom", "Riproduci/Pausa · Controlli zoom"),
        ("ja", "ドラッグ", "回転", "写真", "ズーム", "再生／一時停止・ズーム操作"),
        ("zh-Hans", "拖动", "转动", "照片", "缩放", "播放/暂停 · 缩放控制"),
        ("zh-Hant", "拖曳", "轉動", "照片", "縮放", "播放/暫停 · 縮放控制"),
    ])
    func compactRemoteHintsUseOneWordVisualLabels(
        localeID: String,
        drag: String,
        turn: String,
        photos: String,
        zoom: String,
        zoomShortcut: String
    ) {
        let locale = Locale(identifier: localeID)
        #expect(AppLocalization.string(
            "globe.controls.swipe",
            defaultValue: "Drag",
            locale: locale
        ) == drag)
        #expect(AppLocalization.string(
            "globe.controls.arrows",
            defaultValue: "Turn",
            locale: locale
        ) == turn)
        #expect(AppLocalization.string(
            "globe.controls.select",
            defaultValue: "Photos",
            locale: locale
        ) == photos)
        #expect(AppLocalization.string(
            "globe.controls.zoom",
            defaultValue: "Zoom",
            locale: locale
        ) == zoom)
        #expect(AppLocalization.string(
            "globe.controls.zoom_shortcut",
            defaultValue: "Play/Pause · Zoom controls",
            locale: locale
        ) == zoomShortcut)
    }

    @Test(arguments: [
        ("en", "clickpad center", "touch surface", "Play/Pause", "Back"),
        ("de", "Klickpad-Mitte", "Touch-Oberfläche", "Taste „Wiedergabe/Pause“", "Taste „Zurück“"),
        ("es", "centro del clickpad", "superficie táctil", "Reproducir/Pausa", "botón Atrás"),
        ("fr", "centre du clickpad", "surface tactile", "Lecture/Pause", "bouton Retour"),
        ("it", "centro del clickpad", "superficie touch", "Riproduci/Pausa", "tasto Indietro"),
        ("ja", "クリックパッドの中央", "タッチサーフェス", "再生／一時停止", "戻るボタン"),
        ("zh-Hans", "点按板中央", "触控表面", "播放/暂停", "返回按钮"),
        ("zh-Hant", "觸控板中央", "觸控表面", "播放/暫停", "返回按鈕"),
    ])
    func spokenRemoteHintsUseAppleHardwareVocabulary(
        localeID: String,
        center: String,
        touchSurface: String,
        playPauseButton: String,
        backButton: String
    ) {
        let locale = Locale(identifier: localeID)
        let directControl = AppLocalization.string(
            "globe.controls.touch_accessibility",
            defaultValue: "Swipe on the clickpad or touch surface to drag it, or press the clickpad ring to turn it. Press the clickpad center or touch surface to view photos. Press Play/Pause to open zoom controls.",
            locale: locale
        )
        let zoomControl = AppLocalization.string(
            "globe.zoom.touch_hint",
            defaultValue: "Swipe on the clickpad or touch surface to drag the globe. Press left or right to choose a zoom control. Press the clickpad center or touch surface to activate it, or press Back to close.",
            locale: locale
        )
        let overview = AppLocalization.string(
            "home.explore_hint",
            defaultValue: "Turn the globe with the remote, then press the clickpad center or touch surface to browse visible photos.",
            locale: locale
        )

        for text in [directControl, zoomControl, overview] {
            #expect(text.contains(center))
            #expect(text.contains(touchSurface))
        }
        #expect(directControl.contains(playPauseButton))
        #expect(zoomControl.contains(backButton))
    }

    @Test(arguments: [
        ("en", "Globe zoom controls", "Zoom In", "Zoom Out", "Show Globe Control Hints"),
        ("de", "Zoomsteuerung für den Globus", "Vergrößern", "Verkleinern", "Hinweise zur Globussteuerung anzeigen"),
        ("es", "Controles de zoom del globo", "Acercar", "Alejar", "Mostrar indicaciones de control del globo"),
        ("fr", "Commandes de zoom du globe", "Zoom avant", "Zoom arrière", "Afficher les indications de contrôle du globe"),
        ("it", "Controlli zoom del globo", "Ingrandisci", "Riduci", "Mostra i suggerimenti per controllare il globo"),
        ("ja", "地球儀のズーム操作", "拡大", "縮小", "地球儀の操作ヒントを表示"),
        ("zh-Hans", "地球缩放控制", "放大", "缩小", "显示地球操作提示"),
        ("zh-Hant", "地球縮放控制", "放大", "縮小", "顯示地球操作提示"),
    ])
    func zoomAndSettingsControlLabelsRemainIntentional(
        localeID: String,
        zoomLabel: String,
        zoomIn: String,
        zoomOut: String,
        setting: String
    ) {
        let locale = Locale(identifier: localeID)
        #expect(AppLocalization.string("globe.zoom.accessibility", defaultValue: "Globe zoom controls", locale: locale) == zoomLabel)
        #expect(AppLocalization.string("globe.zoom.in", defaultValue: "Zoom In", locale: locale) == zoomIn)
        #expect(AppLocalization.string("globe.zoom.out", defaultValue: "Zoom Out", locale: locale) == zoomOut)
        #expect(AppLocalization.string("settings.show_hints", defaultValue: "Show Globe Control Hints", locale: locale) == setting)
    }

    @Test(arguments: [
        ("en", "Select"),
        ("de", "Auswähl"),
        ("es", "Seleccion"),
        ("fr", "Sélection"),
        ("it", "Selezion"),
        ("ja", "選択を押"),
        ("zh-Hans", "按“选择”"),
        ("zh-Hant", "按“選擇”"),
    ])
    func centerButtonActionsNeverUseTheSelectionVerb(localeID: String, forbidden: String) {
        let locale = Locale(identifier: localeID)
        let centerActionCopy = [
            AppLocalization.string("detail.playable_viewing_hint", defaultValue: "Left/right: Change memory · Center: Play/pause · Up: More actions", locale: locale),
            AppLocalization.string("detail.viewing_hint", defaultValue: "Left/right: Change photo · Center: More actions", locale: locale),
            AppLocalization.string("globe.controls.accessibility", defaultValue: "Use the direction buttons to turn it. Press the center button to view photos. Press Play/Pause to open zoom controls.", locale: locale),
            AppLocalization.string("globe.controls.zoom_shortcut", defaultValue: "Play/Pause · Zoom controls", locale: locale),
            AppLocalization.string("globe.controls.select", defaultValue: "Photos", locale: locale),
            AppLocalization.string("globe.controls.touch_accessibility", defaultValue: "Swipe on the clickpad or touch surface to drag it, or press the clickpad ring to turn it. Press the clickpad center or touch surface to view photos. Press Play/Pause to open zoom controls.", locale: locale),
            AppLocalization.string("globe.zoom.hint", defaultValue: "Press left or right to choose a zoom control. Press center to activate it, or press Back to close.", locale: locale),
            AppLocalization.string("globe.zoom.touch_hint", defaultValue: "Swipe on the clickpad or touch surface to drag the globe. Press left or right to choose a zoom control. Press the clickpad center or touch surface to activate it, or press Back to close.", locale: locale),
            AppLocalization.string("home.explore_hint", defaultValue: "Turn the globe with the remote, then press the clickpad center or touch surface to browse visible photos.", locale: locale),
            AppLocalization.string("memory_strip.failed", defaultValue: "Previews unavailable", locale: locale),
            AppLocalization.string("memory_strip.no_preview", defaultValue: "No previews yet", locale: locale),
        ]

        for value in centerActionCopy {
            #expect(value.range(of: forbidden, options: [.caseInsensitive, .diacriticInsensitive]) == nil)
        }
    }

    @Test(arguments: [
        ("en", "Unknown place@Japan"),
        ("ja", "不明な場所@日本"),
        ("de", "Unbekannter Ort@Japan"),
        ("fr", "Lieu inconnu@Japon"),
        ("es", "Lugar desconocido@Japón"),
        ("it", "Luogo sconosciuto@Giappone"),
        ("zh-Hans", "未知地点@日本"),
        ("zh-Hant", "未知地點@日本"),
    ])
    func unknownPlaceKeepsAvailableCountryContext(localeID: String, expected: String) {
        let locale = Locale(identifier: localeID)
        let country = locale.localizedString(forRegionCode: "JP")
        #expect(AppLocalization.unknownPlace(near: country, locale: locale) == expected)
        #expect(!AppLocalization.unknownPlace(near: nil, locale: locale).contains("@"))
    }

    @Test(arguments: [
        ("en", "Live Photo", "Video", "Play"),
        ("ja", "Live Photo", "ビデオ", "再生"),
        ("de", "Live Photo", "Video", "Abspielen"),
        ("fr", "Live Photo", "Vidéo", "Lire"),
        ("es", "Live Photo", "Vídeo", "Reproducir"),
        ("it", "Live Photo", "Video", "Riproduci"),
        ("zh-Hans", "实况照片", "视频", "播放"),
        ("zh-Hant", "原況照片", "影片", "播放"),
    ])
    func mediaPlaybackLabelsExistInEverySupportedLanguage(
        localeID: String,
        livePhoto: String,
        video: String,
        play: String
    ) {
        let locale = Locale(identifier: localeID)
        #expect(AppLocalization.string("detail.media_live_photo", defaultValue: "Live Photo", locale: locale) == livePhoto)
        #expect(AppLocalization.string("detail.media_video", defaultValue: "Video", locale: locale) == video)
        #expect(AppLocalization.string("detail.play", defaultValue: "Play", locale: locale) == play)
    }

    @Test(arguments: [
        ("en", "Slideshow", "Return to Photo Wall"),
        ("ja", "スライドショー", "フォトウォールに戻る"),
        ("de", "Diashow", "Zurück zur Fotowand"),
        ("fr", "Diaporama", "Retour au mur de photos"),
        ("es", "Presentación", "Volver al muro de fotos"),
        ("it", "Presentazione", "Torna alla galleria"),
        ("zh-Hans", "放映", "返回照片墙"),
        ("zh-Hant", "放映", "返回照片牆"),
    ])
    func slideshowEntryAndExitExistInEverySupportedLanguage(
        localeID: String,
        start: String,
        returnToWall: String
    ) {
        let locale = Locale(identifier: localeID)
        #expect(AppLocalization.string(
            "slideshow.start",
            defaultValue: "Slideshow",
            locale: locale
        ) == start)
        #expect(AppLocalization.string(
            "slideshow.return_wall",
            defaultValue: "Return to Photo Wall",
            locale: locale
        ) == returnToWall)
    }

    @Test(arguments: [
        ("en", "Connect Apple Music", "Choose Music", "Slideshow Music", "Background Music"),
        ("ja", "Apple Musicに接続", "音楽を選択", "この旅の音楽", "BGM"),
        ("de", "Mit Apple Music verbinden", "Musik auswählen", "Musik für diese Reise", "Hintergrundmusik"),
        ("fr", "Connecter Apple Music", "Choisir la musique", "Musique de ce voyage", "Musique de fond"),
        ("es", "Conectar Apple Music", "Elegir música", "Música para este viaje", "Música de fondo"),
        ("it", "Collega Apple Music", "Scegli musica", "Musica per questo viaggio", "Musica di sottofondo"),
        ("zh-Hans", "连接 Apple Music", "选择配乐", "为这段旅程配乐", "背景音乐"),
        ("zh-Hant", "連接 Apple Music", "選擇配樂", "為這段旅程配樂", "背景音樂"),
    ])
    func appleMusicSelectionExistsInEverySupportedLanguage(
        localeID: String,
        connect: String,
        choose: String,
        title: String,
        controlTitle: String
    ) {
        let locale = Locale(identifier: localeID)
        #expect(AppLocalization.string(
            "slideshow.music.connect",
            defaultValue: "Connect Apple Music",
            locale: locale
        ) == connect)
        #expect(AppLocalization.string(
            "slideshow.music.choose",
            defaultValue: "Choose Music",
            locale: locale
        ) == choose)
        #expect(AppLocalization.string(
            "slideshow.music.title",
            defaultValue: "Slideshow Music",
            locale: locale
        ) == title)
        #expect(AppLocalization.string(
            "slideshow.music.control_title",
            defaultValue: "Background Music",
            locale: locale
        ) == controlTitle)
    }

    @Test func localizedPlaceCachesCoexistWithoutRescanningPhotoRows() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("index.sqlite")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinate = GeoCoordinate(latitude: -33.8688, longitude: 151.2093)
        let place = TravelPlace(
            id: "place-sydney",
            name: "Sydney",
            country: "Australia",
            regionCode: "AU",
            coordinate: coordinate,
            startDate: date,
            endDate: date,
            photoCount: 1,
            coverAssetID: "photo-sydney"
        )
        let photo = PhotoAssetRecord(
            id: "photo-sydney",
            coordinate: coordinate,
            creationDate: date,
            pixelWidth: 1920,
            pixelHeight: 1080,
            isFavorite: false,
            placeID: place.id
        )
        let snapshot = TravelIndexSnapshot(
            index: TravelIndex(
                schemaVersion: TravelIndex.currentSchemaVersion,
                generatedAt: date,
                sourcePhotoCount: 1,
                locatedPhotoCount: 1,
                places: [place],
                journeys: []
            ),
            photos: [photo]
        )

        let englishStore = SQLiteTravelIndexStore(databaseURL: url, locale: Locale(identifier: "en"))
        try await englishStore.save(snapshot)
        let japaneseStore = SQLiteTravelIndexStore(databaseURL: url, locale: Locale(identifier: "ja"))
        let beforeJapaneseLookup = try #require(try await japaneseStore.load())
        #expect(beforeJapaneseLookup.locatedPhotoCount == 1)
        #expect(beforeJapaneseLookup.places[0].name.isEmpty)
        #expect(beforeJapaneseLookup.places[0].country == nil)
        #expect(try await japaneseStore.placeLabelJobs(now: Date()).count == 1)

        _ = try await japaneseStore.recordLabelAttempt(
            beforeJapaneseLookup.places[0],
            label: PlaceDisplayLabel(
                city: "シドニー",
                country: "オーストラリア",
                regionCode: "AU",
                source: JourneyPlaceCatalog.citySource,
                sourceVersion: WorldCityAtlas.revision,
                offlinePlaceID: "fixture-sydney"
            ),
            attempts: 1,
            nextRetryAt: nil
        )

        let englishReload = try #require(try await englishStore.load())
        let japaneseReload = try #require(try await japaneseStore.load())
        #expect(englishReload.locatedPhotoCount == 1)
        #expect(englishReload.places[0].name == "Sydney")
        #expect(englishReload.places[0].country == "Australia")
        #expect(japaneseReload.places[0].name == "シドニー")
        #expect(japaneseReload.places[0].country == "オーストラリア")
        #expect(try await japaneseStore.placeLabelJobs(now: Date()).isEmpty)

        let simplifiedStore = SQLiteTravelIndexStore(databaseURL: url, locale: Locale(identifier: "zh-Hans"))
        let beforeSimplifiedLookup = try #require(try await simplifiedStore.load())
        _ = try await simplifiedStore.recordLabelAttempt(
            beforeSimplifiedLookup.places[0],
            label: PlaceDisplayLabel(city: "悉尼", country: "澳大利亚", regionCode: "AU"),
            attempts: 1,
            nextRetryAt: nil
        )

        let traditionalStore = SQLiteTravelIndexStore(databaseURL: url, locale: Locale(identifier: "zh-Hant"))
        let beforeTraditionalLookup = try #require(try await traditionalStore.load())
        #expect(beforeTraditionalLookup.locatedPhotoCount == 1)
        #expect(beforeTraditionalLookup.places[0].name.isEmpty)
        #expect(beforeTraditionalLookup.places[0].country == nil)
        _ = try await traditionalStore.recordLabelAttempt(
            beforeTraditionalLookup.places[0],
            label: PlaceDisplayLabel(city: "雪梨", country: "澳洲", regionCode: "AU"),
            attempts: 1,
            nextRetryAt: nil
        )

        let simplifiedReload = try #require(try await simplifiedStore.load())
        let traditionalReload = try #require(try await traditionalStore.load())
        #expect(simplifiedReload.places[0].name == "悉尼")
        #expect(simplifiedReload.places[0].country == "澳大利亚")
        #expect(traditionalReload.places[0].name == "雪梨")
        #expect(traditionalReload.places[0].country == "澳洲")
    }
}
