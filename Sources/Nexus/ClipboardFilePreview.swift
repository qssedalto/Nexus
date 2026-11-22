import AppKit
import ImageIO
import QuickLookThumbnailing
import NexusCore
import SwiftUI
import UniformTypeIdentifiers

/// Quick Look is only invoked for a user-authorized, locally available,
/// metadata-bounded file. It does not scan directories or fetch cloud-only
/// files. Failed previews fall back to the existing SF Symbol.
struct ClipboardFilePreview: View {
    let sourcePath: String?
    let fallbackIcon: String

    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: fallbackIcon)
                    .font(.system(size: 31, weight: .ultraLight))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 57, maxHeight: 77)
        .task(id: sourcePath) {
            thumbnail = nil
            guard let sourcePath else { return }
            // File metadata retrieval may wait for file-system providers.
            // Never run it in SwiftUI layout or the main event loop.
            let eligibleURL = await Task.detached(priority: .utility) {
                ClipboardFilePreviewPolicy.eligibleLocalURL(path: sourcePath)
            }.value
            guard !Task.isCancelled, let eligibleURL else { return }
            let bytes = await ClipboardQuickLookRenderer.render(url: eligibleURL)
            guard !Task.isCancelled else { return }
            thumbnail = bytes.flatMap { NSImage(data: $0) }
        }
    }
}

/// Quick Look's asynchronous API supplies a small CGImage; encode it as
/// bounded PNG bytes on its callback queue before handing the Sendable Data
/// across Swift 6 concurrency boundaries into the SwiftUI main actor.
private enum ClipboardQuickLookRenderer {
    static func render(url: URL) async -> Data? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 180, height: 80),
            scale: 2,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                representation, _ in
                guard let image = representation?.cgImage,
                      image.width > 0, image.height > 0,
                      image.width <= 720, image.height <= 720,
                      image.width * image.height <= 250_000 else {
                    continuation.resume(returning: nil)
                    return
                }
                let result = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    result, UTType.png.identifier as CFString, 1, nil
                ) else {
                    continuation.resume(returning: nil)
                    return
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination),
                      result.length > 0, result.length <= 512 * 1_024 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: result as Data)
            }
        }
    }
}
