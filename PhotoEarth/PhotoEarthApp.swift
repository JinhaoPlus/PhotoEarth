//
//  PhotoEarthApp.swift
//  PhotoEarth
//
//  Created by doupi on 2026/9/4.
//

import SwiftUI

@main
struct PhotoEarthApp: App {
#if DEBUG && !targetEnvironment(simulator)
    nonisolated static func usesIsolatedAlbumHost(_ environment: [String: String]) -> Bool {
        environment["PHOTOEARTH_REAL_TV_ALBUM_SCOPE"] == "1" && environment["PHOTOEARTH_REAL_TV_SHELF"] != "1"
    }
#endif

    init() {
        ProductAnalytics.shared.capture(.appOpened)
    }

    var body: some Scene {
        WindowGroup {
#if DEBUG && !targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--qa-cover-benchmark") {
                Color.black.task { await CityCoverTimingQA.run() }
            } else if Self.usesIsolatedAlbumHost(ProcessInfo.processInfo.environment) {
                // An album-only run owns isolated databases. A combined Top Shelf
                // run requires the normal host to publish through its real AppModel.
                Color.black
            } else {
                DeviceRecordingHost(content: PurchaseGate())
            }
#else
            PurchaseGate()
#endif
        }
    }
}
