import UIKit
import Vision
import XCTest

/// Opt-in operation on the paired television's actual Home Screen.
@MainActor final class TVHomeShelfLayoutUITests: XCTestCase {
    private let board = XCUIApplication(bundleIdentifier: "com.apple.PineBoard")
    private let remote = XCUIRemote.shared
    private let appNames = ["PhotoEarth", "Photo Earth", "照片地球"]
    private let editNames = ["Edit Home Screen", "Edit Home Screen Layout", "编辑主屏幕布局", "编辑主屏幕", "編輯主畫面佈局", "編輯主畫面"]
    private let bundleID = "com.doupi.PhotoEarth.PhotoEarth"

    func testMovePhotoEarthToFirstHomeRow() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical Apple TV")
#else
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PHOTOEARTH_MOVE_HOME_ICON"] == "1")
        continueAfterFailure = false
        defer { capture("Home Screen · final state") }

        // An operator can preselect PhotoEarth in DeviceHub. This path never navigates before the hold.
        // A fresh visual confirmation also permits a hold-only handoff on OS versions hiding icon AX.
        let manual = env["PHOTOEARTH_HOME_FOCUS_CONFIRMED_AT"].flatMap(Double.init)
        let holdOnly = env["PHOTOEARTH_HOME_HOLD_ONLY"] == "1"
        let deadline = Date().addingTimeInterval(40)
        while board.state != .runningForeground && Date() < deadline { pause() }
        try require(board.state == .runningForeground, "Show the tvOS Home Screen and focus PhotoEarth")
        capture("Home Screen · before layout")

        if manual == nil {
            try focusPhotoEarth()
        } else if !photoEarthIsFocused {
            let age = Date().timeIntervalSince1970 - (manual ?? 0)
            try require((0...90).contains(age), "The on-screen focus confirmation expired")
            try require(try focusedCaptionIsPhotoEarth(), "The on-screen selected icon caption did not match PhotoEarth")
        }
        if firstRowIsFocusedPhotoEarth {
            capture("Home Screen · PhotoEarth already in first row")
            return
        }

        // Recheck immediately before the sole long press. No long press can target another app.
        if !photoEarthIsFocused {
            guard let manual else { throw failure("PhotoEarth lost focus before the long press") }
            try require((0...90).contains(Date().timeIntervalSince1970 - manual)
                        && (try focusedCaptionIsPhotoEarth()), "PhotoEarth focus could not be verified at the hold")
        }
        remote.press(.select, forDuration: 1.5)
        pause(0.7)
        capture("Home Screen · PhotoEarth long press")
        if holdOnly {
            throw XCTSkip("Verified long press delivered. Inspect the attached system menu and continue in DeviceHub.")
        }

        let edit = board.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", editNames)).firstMatch
        try require(edit.waitForExistence(timeout: 5), "The edit action is hidden from AX. Inspect the captured menu in DeviceHub.")
        for _ in 0..<8 {
            if isFocused(edit) { break }
            guard let active = focusedElement, !active.frame.isEmpty, !edit.frame.isEmpty else {
                throw failure("Cannot safely identify the focused menu item")
            }
            remote.press(active.frame.midY < edit.frame.midY ? .down : .up)
            pause()
        }
        try require(isFocused(edit), "The selected menu command must be Edit Home Screen")
        remote.press(.select)
        pause(0.8)
        capture("Home Screen · editing PhotoEarth")
        try require(!edit.exists && photoEarthIsFocused, "Cannot identify PhotoEarth in the editing grid")

        for _ in 0..<20 {
            if firstRowIsFocusedPhotoEarth { break }
            try require(photoEarthIsFocused && !iconsAbovePhotoEarth.isEmpty,
                        "The next upward move cannot be verified in the editing grid")
            remote.press(.up)
            pause(0.5)
        }
        try require(firstRowIsFocusedPhotoEarth, "Could not verify the first row. Inspect the saved editing state.")
        remote.press(.select)
        pause(0.8)
        try require(firstRowIsFocusedPhotoEarth, "Verify the saved first-row location in DeviceHub")
        capture("Home Screen · PhotoEarth first row saved")
#endif
    }

    private var focusedElement: XCUIElement? {
        let element = board.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == YES")).firstMatch
        return element.exists ? element : nil
    }

    private var icon: XCUIElement {
        board.descendants(matching: .icon).matching(NSPredicate(
            format: "label IN %@ OR identifier == %@", appNames, bundleID
        )).firstMatch
    }

    private var photoEarthIsFocused: Bool {
        guard board.state == .runningForeground, let focused = focusedElement else { return false }
        return focused.identifier == bundleID || appNames.contains(focused.label) || (icon.exists && isFocused(icon))
    }

    private func isFocused(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        if element.hasFocus { return true }
        guard let focused = focusedElement, !focused.frame.isEmpty,
              focused.frame.width < board.frame.width * 0.48,
              focused.frame.height < board.frame.height * 0.48 else { return false }
        // Some OS builds put Focus on the enclosing cell and publish the caption as its child.
        return focused.descendants(matching: .any).matching(NSPredicate(format: "label == %@", element.label)).firstMatch.exists
    }

    private var iconsAbovePhotoEarth: [XCUIElement] {
        guard icon.exists else { return [] }
        let frame = icon.frame
        return board.descendants(matching: .icon).allElementsBoundByIndex.filter {
            !$0.frame.isEmpty && $0.frame.midY < frame.midY - frame.height * 0.65
        }
    }

    private var firstRowIsFocusedPhotoEarth: Bool {
        guard photoEarthIsFocused, icon.exists, iconsAbovePhotoEarth.isEmpty else { return false }
        let frame = icon.frame, screen = board.frame
        let peers = board.descendants(matching: .icon).allElementsBoundByIndex.filter {
            !$0.frame.isEmpty && abs($0.frame.midY - frame.midY) < frame.height * 0.4
        }
        // First-row focus leaves the upper half to Top Shelf. A partly clipped top row midway
        // through a scrolled grid must not be mistaken for index zero.
        return peers.count >= 5 && screen.contains(CGPoint(x: frame.midX, y: frame.midY))
            && frame.midY > screen.minY + screen.height * 0.56
    }

    private func focusPhotoEarth() throws {
        for _ in 0..<24 {
            if photoEarthIsFocused { return }
            guard let selected = focusedElement, selected.elementType == .icon,
                  !selected.frame.isEmpty else {
                throw failure("Preselect PhotoEarth in DeviceHub. The current focused grid item is not exposed.")
            }
            let target = icon
            if !target.exists {
                remote.press(.down)
            } else if abs(target.frame.midY - selected.frame.midY) > selected.frame.height * 0.55 {
                remote.press(target.frame.midY < selected.frame.midY ? .up : .down)
            } else {
                remote.press(target.frame.midX < selected.frame.midX ? .left : .right)
            }
            pause()
        }
        throw failure("PhotoEarth was not reached using the native grid")
    }

    /// tvOS shows a caption under the selected app. Restrict OCR to the lower three quarters
    /// of the Home Screen and require an exact label after an external visual confirmation.
    private func focusedCaptionIsPhotoEarth() throws -> Bool {
        // A named, focused AX icon takes precedence over the visual handoff.
        if let selected = focusedElement, selected.elementType == .icon, !selected.label.isEmpty,
           !appNames.contains(selected.label), selected.identifier != bundleID { return false }
        guard let image = XCUIScreen.main.screenshot().image.cgImage else { return false }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "zh-Hans"]
        request.usesLanguageCorrection = false
        request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 0.75)
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.contains {
            guard let label = $0.topCandidates(1).first?.string else { return false }
            return appNames.contains(label.trimmingCharacters(in: .whitespacesAndNewlines))
        } == true
    }

    private func capture(_ title: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = title
        shot.lifetime = .keepAlways
        add(shot)
        if board.state == .runningForeground {
            let tree = XCTAttachment(string: board.debugDescription)
            tree.name = title + " · PineBoard AX"
            tree.lifetime = .keepAlways
            add(tree)
        }
    }

    private func pause(_ duration: TimeInterval = 0.32) {
        RunLoop.current.run(until: Date().addingTimeInterval(duration))
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw failure(message) }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "TVHomeShelfLayout", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
