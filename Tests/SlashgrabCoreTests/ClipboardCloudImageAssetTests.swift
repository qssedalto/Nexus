import CloudKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SlashgrabCore

final class ClipboardCloudImageAssetTests: XCTestCase {
    private func samplePNG() throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 5, height: 5, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.3, green: 0.7,
                                     blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 5, height: 5))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    func testAssetIntegrityAndSafePreview() throws {
        let png = try samplePNG()
        let asset = try XCTUnwrap(ClipboardCloudImageAsset(
            bytes: png, pasteboardType: "public.png"
        ))
        XCTAssertTrue(asset.reference.isStructurallyValid)
        XCTAssertTrue(asset.reference.verifies(png))
        XCTAssertNotNil(ClipboardCloudImagePreview.thumbnail(png))
        XCTAssertFalse(asset.reference.verifies(Data(png.dropLast())))
        XCTAssertNil(ClipboardCloudImageAsset(
            bytes: png, pasteboardType: "public.html"
        ))
        XCTAssertNil(ClipboardCloudImageAsset(
            bytes: Data(), pasteboardType: "public.png"
        ))
        XCTAssertNil(ClipboardCloudImageAsset(
            bytes: Data(repeating: 1, count: 8 * 1_024 * 1_024 + 1),
            pasteboardType: "public.png"
        ))
    }

    func testImageIsSeparateFromCloudMetadataAndExplicitlyGated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try OperationStore(url: root.appendingPathComponent("source.sqlite"))
        let journal = try ClipboardCloudJournal(url: root.appendingPathComponent("source-journal.sqlite"))
        let png = try samplePNG()
        let thumbnail = try XCTUnwrap(ClipboardCloudImagePreview.thumbnail(png))
        let originalID = try source.recordClipboardImage(
            data: png, thumbnail: thumbnail, pasteboardType: "public.png",
            detectedTimeMS: 43
        )
        let metadataConsent = ClipboardCloudConsent(enabled: true)
        _ = try ClipboardCloudLocalSnapshot.stagePage(
            from: source, in: journal,
            deviceID: "mac-A", consent: metadataConsent
        )
        let meta = try XCTUnwrap(journal.record(
            id: ClipboardCloudRecord.operationID(originalID)
        ))
        guard case .operation(let metaPayload)? = meta.payload else {
            return XCTFail("missing operation")
        }
        XCTAssertNil(metaPayload.image, "A basic CloudKit toggle must never transfer images")
        let imageConsent = ClipboardCloudConsent(enabled: true, includeImages: true)
        _ = try ClipboardCloudLocalSnapshot.stagePage(
            from: source, in: journal,
            deviceID: "mac-A", consent: imageConsent
        )
        let transfer = try XCTUnwrap(journal.record(
            id: ClipboardCloudRecord.operationID(originalID)
        ))
        guard case .operation(let imageInfo)? = transfer.payload else {
            return XCTFail("missing authorized operation")
        }
        let reference = try XCTUnwrap(imageInfo.image)
        let asset = try XCTUnwrap(ClipboardCloudImageAsset(
            bytes: png, pasteboardType: "public.png"
        ))
        XCTAssertTrue(asset.matches(reference))
        XCTAssertFalse(metadataConsent.permits(transfer))
        XCTAssertTrue(imageConsent.permits(transfer))

        let zone = CKRecordZone.ID(
            zoneName: "NexusClipboard", ownerName: CKCurrentUserDefaultName
        )
        let encoded = try ClipboardCloudKitCodec.encode(transfer, zoneID: zone)
        XCTAssertNil(encoded["imageAsset"], "Original bytes must remain outside JSON")
        XCTAssertEqual(
            try ClipboardCloudKitCodec.decode(encoded, expectedZoneID: zone),
            transfer
        )
    }

    func testBinaryAssetRestoreIsAtomicWithCloudCursorAndDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try OperationStore(url: root.appendingPathComponent("source.sqlite"))
        let target = try OperationStore(url: root.appendingPathComponent("target.sqlite"))
        let journal = try ClipboardCloudJournal(url: root.appendingPathComponent("journal.sqlite"))
        let png = try samplePNG()
        let thumbnail = try XCTUnwrap(ClipboardCloudImagePreview.thumbnail(png))
        let originalID = try source.recordClipboardImage(
            data: png, thumbnail: thumbnail, pasteboardType: "public.png",
            detectedTimeMS: 700
        )
        let consent = ClipboardCloudConsent(enabled: true, includeImages: true)
        _ = try ClipboardCloudLocalSnapshot.stagePage(
            from: source, in: journal, deviceID: "MacA", consent: consent
        )
        let record = try XCTUnwrap(journal.pending().first)
        let remote = try ClipboardCloudJournal(
            url: root.appendingPathComponent("remote-journal.sqlite")
        )
        let asset = try XCTUnwrap(ClipboardCloudImageAsset(
            bytes: png, pasteboardType: "public.png"
        ))
        let token = Data([1, 3, 5])
        let corrupted = try XCTUnwrap(ClipboardCloudImageAsset(
            bytes: Data([1, 2, 3]), pasteboardType: "public.png"
        ))
        XCTAssertThrowsError(try remote.applyRemote(
            [record], zoneID: "NexusClipboard",
            changeToken: token, imageAssets: [record.id: corrupted]
        ))
        XCTAssertNil(try remote.token(forZone: "NexusClipboard"))
        XCTAssertNil(try remote.record(id: record.id))

        XCTAssertEqual(try remote.applyRemote(
            [record], zoneID: "NexusClipboard",
            changeToken: token, imageAssets: [record.id: asset]
        ), 1)
        XCTAssertEqual(try remote.token(forZone: "NexusClipboard"), token)
        XCTAssertEqual(try remote.cachedImage(recordID: record.id)?.bytes, png)

        let cached = try remote.cachedRecords(limit: 10)
        XCTAssertEqual(try target.importCloudHistory(
            cached, consent: consent, cloudImageProvider: {
                try remote.cachedImage(recordID: $0)
            }
        ), 1)
        let mirrored = try XCTUnwrap(target.imageContent(
            operationID: "cloudkit:" + originalID
        ))
        XCTAssertEqual(mirrored.pasteboardType, "public.png")
        XCTAssertEqual(mirrored.data, png)
        XCTAssertNotNil(try target.imageThumbnail(
            operationID: "cloudkit:" + originalID
        ))
        XCTAssertEqual(try target.imageBlobCount(), 1)

        // Same page may be replayed without duplicate history or blob rows.
        XCTAssertEqual(try target.importCloudHistory(
            cached, consent: consent, cloudImageProvider: {
                try remote.cachedImage(recordID: $0)
            }
        ), 0)
        XCTAssertEqual(try target.imageBlobCount(), 1)

        let tombstone = record.tombstone(
            revision: ClipboardCloudRevision(counter: 2, deviceID: "MacB")
        )
        XCTAssertEqual(try remote.applyRemote(
            [tombstone], zoneID: "NexusClipboard",
            changeToken: Data([2])
        ), 1)
        XCTAssertNil(try remote.cachedImage(recordID: record.id))
        XCTAssertEqual(try target.importCloudHistory(
            [tombstone], consent: consent
        ), 0)
        XCTAssertNil(try target.imageContent(
            operationID: "cloudkit:" + originalID
        ))
        XCTAssertEqual(try target.imageBlobCount(), 0)
    }

    func testCachePurgeDeletesImageBytesWithoutDeletingOriginals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try OperationStore(url: root.appendingPathComponent("original.sqlite"))
        let journal = try ClipboardCloudJournal(url: root.appendingPathComponent("cloud.sqlite"))
        let png = try samplePNG()
        let thumbnail = try XCTUnwrap(ClipboardCloudImagePreview.thumbnail(png))
        let id = try original.recordClipboardImage(
            data: png, thumbnail: thumbnail,
            pasteboardType: "public.png", detectedTimeMS: 99
        )
        let consent = ClipboardCloudConsent(enabled: true, includeImages: true)
        _ = try ClipboardCloudLocalSnapshot.stagePage(
            from: original, in: journal, deviceID: "MacA", consent: consent
        )
        let record = try XCTUnwrap(journal.pending().first)
        let asset = try XCTUnwrap(ClipboardCloudImageAsset(
            bytes: png, pasteboardType: "public.png"
        ))
        try journal.applyRemote([record], imageAssets: [record.id: asset])
        XCTAssertNotNil(try journal.cachedImage(recordID: record.id))
        try journal.discardAllLocalCloudData()
        XCTAssertNil(try journal.cachedImage(recordID: record.id))
        XCTAssertTrue(try journal.cachedRecords().isEmpty)
        XCTAssertEqual(try original.imageContent(operationID: id)?.data, png)
    }
}
