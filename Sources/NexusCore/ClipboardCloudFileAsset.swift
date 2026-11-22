import CryptoKit
import Foundation

/// Only one small, existing regular file per clipboard event is currently
/// transferable. No recursive folder traversal, symlink dereferencing or
/// transparent File Provider hydration. Original paths never leave the Mac.
public struct ClipboardCloudFileReference: Codable, Sendable, Equatable {
    public static let maximumBytes = 8 * 1_024 * 1_024
    public let fileName: String
    public let byteCount: Int
    public let digest: String

    public static func acceptableName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            }) && name.utf8.count <= 200
    }

    public init?(bytes: Data, fileName: String) {
        guard Self.acceptableName(fileName), !bytes.isEmpty,
              bytes.count <= Self.maximumBytes else { return nil }
        self.fileName = fileName
        byteCount = bytes.count
        var hasher = SHA256()
        hasher.update(data: Data(fileName.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: bytes)
        digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public var isStructurallyValid: Bool {
        Self.acceptableName(fileName) && byteCount > 0
            && byteCount <= Self.maximumBytes && digest.utf8.count == 64
            && digest.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdef").contains($0)
            }
    }

    public func verifies(_ bytes: Data) -> Bool {
        guard isStructurallyValid,
              let decoded = Self(bytes: bytes, fileName: fileName) else { return false }
        return decoded == self
    }
}

public struct ClipboardCloudFileAsset: Sendable, Equatable {
    public let bytes: Data
    public let reference: ClipboardCloudFileReference

    public init?(bytes: Data, fileName: String) {
        guard let reference = ClipboardCloudFileReference(
            bytes: bytes, fileName: fileName
        ) else { return nil }
        self.bytes = bytes
        self.reference = reference
    }

    public func matches(_ reference: ClipboardCloudFileReference) -> Bool {
        self.reference == reference && reference.verifies(bytes)
    }
}
