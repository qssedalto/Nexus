import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A bounded, content-verified clipboard image, transferred through CKAsset
/// only after separate explicit consent. Never embeds original pixels in the
/// JSON CloudKit document, telemetry, metadata previews or sync diagnostics.
public struct ClipboardCloudImageReference: Codable, Sendable, Equatable {
    public static let maximumBytes = 8 * 1_024 * 1_024
    public static let allowedTypes: Set<String> = [
        "public.png", "public.tiff", "public.jpeg", "public.heic",
        "com.compuserve.gif"
    ]

    public let pasteboardType: String
    public let byteCount: Int
    public let digest: String

    public init?(bytes: Data, pasteboardType: String) {
        guard Self.allowedTypes.contains(pasteboardType),
              !bytes.isEmpty, bytes.count <= Self.maximumBytes else { return nil }
        self.pasteboardType = pasteboardType
        byteCount = bytes.count
        var hasher = SHA256()
        hasher.update(data: Data(pasteboardType.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: bytes)
        digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public var isStructurallyValid: Bool {
        Self.allowedTypes.contains(pasteboardType)
            && byteCount > 0 && byteCount <= Self.maximumBytes
            && digest.utf8.count == 64
            && digest.unicodeScalars.allSatisfy {
                ("0"..."9").contains(String($0)) || ("a"..."f").contains(String($0))
            }
    }

    public func verifies(_ bytes: Data) -> Bool {
        guard isStructurallyValid, let rebuilt = Self(
            bytes: bytes, pasteboardType: pasteboardType
        ) else { return false }
        return rebuilt == self
    }
}

public struct ClipboardCloudImageAsset: Sendable, Equatable {
    public let bytes: Data
    public let reference: ClipboardCloudImageReference

    public init?(bytes: Data, pasteboardType: String) {
        guard let reference = ClipboardCloudImageReference(
            bytes: bytes, pasteboardType: pasteboardType
        ) else { return nil }
        self.bytes = bytes
        self.reference = reference
    }

    public func matches(_ metadata: ClipboardCloudImageReference) -> Bool {
        metadata == reference && metadata.verifies(bytes)
    }
}

/// Bounded preview decoder shared by Apple clients. A tiny compressed image
/// may expand to enormous dimensions; validate headers before any decode.
public enum ClipboardCloudImagePreview {
    public static func thumbnail(_ bytes: Data) -> Data? {
        guard !bytes.isEmpty,
              bytes.count <= ClipboardCloudImageReference.maximumBytes,
              let source = CGImageSourceCreateWithData(
                bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source, 0, nil
              ) as? NSDictionary,
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.int64Value > 0, height.int64Value > 0,
              width.int64Value <= 20_000, height.int64Value <= 20_000,
              width.int64Value * height.int64Value <= 40_000_000 else {
            return nil
        }
        for dimension in [320, 240, 160] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false,
                kCGImageSourceThumbnailMaxPixelSize: dimension
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary
            ) else { return nil }
            let out = NSMutableData()
            guard let writer = CGImageDestinationCreateWithData(
                out, UTType.jpeg.identifier as CFString, 1, nil
            ) else { return nil }
            CGImageDestinationAddImage(
                writer, image,
                [kCGImageDestinationLossyCompressionQuality: 0.76] as CFDictionary
            )
            guard CGImageDestinationFinalize(writer) else { return nil }
            if out.length > 0 && out.length <= 256 * 1_024 {
                return out as Data
            }
        }
        return nil
    }
}
