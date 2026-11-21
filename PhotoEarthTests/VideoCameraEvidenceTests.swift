import AVFoundation
import Foundation
import SQLite3
import Testing
@testable import PhotoEarth

@Suite(.serialized)
struct VideoCameraEvidenceTests {
    private func field(_ identifier: AVMetadataIdentifier, _ value: String?) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString?
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    @Test func cameraTagsTakePrecedenceOverLensAndUnreadableFieldsInEitherOrder() async throws {
        for id in [AVMetadataIdentifier.quickTimeUserDataMake, .quickTimeUserDataModel,
                   .quickTimeMetadataMake, .quickTimeMetadataModel, .commonIdentifierMake, .commonIdentifierModel] {
            let lens = field(.quickTimeMetadataCameraLensModel, "Lens")
            let device = field(id, "Device")
            for items in [[lens, device], [device, lens]] {
                var fields = VideoCameraFields()
                try await fields.inspect(items)
                #expect(fields.evidence == .identified)
            }
        }
        for item in [field(.quickTimeMetadataCameraLensModel, "Lens"), field(.quickTimeUserDataMake, "  "),
                     field(.quickTimeMetadataModel, nil)] {
            var fields = VideoCameraFields()
            try await fields.inspect([item])
            #expect(fields.evidence == .unknown)
        }
        let composition = AVMutableComposition()
        let incomplete = await CameraEvidenceReader.videoEvidence(in: composition)
        #expect(incomplete == .unknown)
        let nonexistent = AVURLAsset(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov"))
        let unreadable = await CameraEvidenceReader.videoEvidence(in: nonexistent)
        #expect(unreadable == .unknown)
    }

    @Test func readsQuickTimeUserDataFromActualOriginalMovie() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let samples: [(String, [AVMetadataItem], CameraEvidence)] = [
            ("user-model", [field(.quickTimeUserDataModel, "Fixture camera")], .identified),
            ("lens-only", [field(.quickTimeMetadataCameraLensModel, "Fixture lens")], .unknown),
            ("no-tags", [], .confirmedMissing)
        ]
        for (name, metadata, expected) in samples {
            let url = dir.appendingPathComponent(name + ".mov")
            try await writeMovie(to: url, metadata: metadata)
            let result = await CameraEvidenceReader.videoEvidence(in: AVURLAsset(url: url))
            #expect(result == expected)
        }
    }

    private func writeMovie(to url: URL, metadata: [AVMetadataItem]) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = metadata
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let bufferInput = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var pixels: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
        guard status == kCVReturnSuccess, let pixels, bufferInput.append(pixels, withPresentationTime: .zero) else {
            writer.cancelWriting()
            throw CocoaError(.fileWriteUnknown)
        }
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 30))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    @Test(arguments: [true, false])
    func legacyVideoNegativesAreRetriedOnceWithoutInvalidatingPhotosOrIdentifiedVideos(excluded: Bool) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ledger.sqlite")
        var connection: OpaquePointer?
        guard sqlite3_open(url.path, &connection) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        let seed = """
            CREATE TABLE scan_identity(id INTEGER PRIMARY KEY, identity TEXT NOT NULL);
            INSERT INTO scan_identity VALUES(1,'prior-identity');
            CREATE TABLE evidence(id TEXT PRIMARY KEY, modified REAL, camera INTEGER, decision INTEGER, checked REAL, sweep TEXT, media INTEGER, excluded_revision INTEGER DEFAULT 0);
            INSERT INTO evidence VALUES ('old-video',1,2,\(excluded ? 6 : 0),100,'s',2,4),
                ('camera-video',1,1,0,100,'s',2,0), ('negative-photo',1,2,6,100,'s',0,3),
                ('live-photo',1,1,0,100,'s',1,0), ('excluded-album-video',1,2,2,100,'s',2,0);
            PRAGMA user_version=4;
            """
        let seeded = sqlite3_exec(connection, seed, nil, nil, nil)
        sqlite3_close(connection)
        try #require(seeded == SQLITE_OK)

        let ledger = TravelScanLedger(url: url)
        let version = try await ledger.prepare(.init())
        #expect(version.revision == 4)
        #expect(version.scope.hasSuffix("prior-identity") == !excluded)
        let pending = try await ledger.pending()
        #expect(pending.map(\.id) == ["old-video"])
        #expect(try await ledger.counts() == [.eligible: 2, .noCamera: 1, .excludedAlbum: 1, .pendingCamera: 1])
        #expect(try await ledger.removals(after: 0, startingAfter: "") == ["negative-photo"])
        let checked = try #require(pending.first)
        #expect(try await ledger.record(.confirmedMissing, for: checked))

        let reopened = TravelScanLedger(url: url)
        let again = try await reopened.prepare(.init())
        #expect(again.scope == version.scope && again.revision == 5)
        #expect(try await reopened.pending().isEmpty)
        #expect(try await reopened.counts() == [.eligible: 2, .noCamera: 2, .excludedAlbum: 1])
    }
}
