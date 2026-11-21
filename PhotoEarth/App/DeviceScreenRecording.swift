#if DEBUG && !targetEnvironment(simulator)
import ReplayKit
import SwiftUI

/// Opt-in physical-device QA. Production builds contain no recording entry point.
@MainActor
struct DeviceRecordingHost<Content: View>: View {
    let content: Content
    @State private var state = "waiting"
    @State private var started = false

    var body: some View {
        if let seconds {
            content
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("qa-device-recording-\(state)")
                .task {
                    guard !started else { return }
                    started = true
                    await record(seconds: seconds)
                }
        } else {
            content
        }
    }

    private var seconds: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--qa-device-record-seconds"),
              arguments.indices.contains(flag + 1), let value = Int(arguments[flag + 1]),
              (50...150).contains(value) else { return nil }
        return value
    }

    private func record(seconds: Int) async {
        let recorder = RPScreenRecorder.shared()
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("PhotoEarthQA", isDirectory: true)
        let clip = directory.appendingPathComponent("device-screen.mp4")
        let status = directory.appendingPathComponent("device-screen-status.txt")
        func publish(_ phase: String, detail: String? = nil) {
            state = phase
            let line = [Date().ISO8601Format(), phase, detail].compactMap { $0 }.joined(separator: " ")
            try? (line + "\n").write(to: status, atomically: true, encoding: .utf8)
        }
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            if files.fileExists(atPath: clip.path) { try files.removeItem(at: clip) }
            publish("waiting")
            guard recorder.isAvailable, !recorder.isRecording else {
                publish("failed", detail: "ReplayKit unavailable or already recording")
                return
            }
            // tvOS exposes app-screen recording only; ReplayKit's camera and
            // microphone controls are unavailable on this platform.
            try await withCheckedThrowingContinuation { (approval: CheckedContinuation<Void, Error>) in
                recorder.startRecording { error in
                    if let error { approval.resume(throwing: error) } else { approval.resume() }
                }
            }
            publish("active")
            try? await Task.sleep(for: .seconds(seconds))
            try await recorder.stopRecording(withOutput: clip)
            publish("saved")
        } catch {
            publish("failed", detail: error.localizedDescription)
        }
    }
}
#endif
