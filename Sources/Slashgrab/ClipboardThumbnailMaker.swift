import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decode only a bounded thumbnail of an explicitly authorized image.
/// Never retains decoded full-size pixels or logs clipboard content.
enum ClipboardThumbnailMaker {
    static func jpegPreview(from data: Data) -> Data? {
        guard !data.isEmpty, data.count <= 8 * 1_024 * 1_024 else { return nil }
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        for maximumDimension in [320, 240, 160] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary
            ) else { return nil }
            let output = NSMutableData()
            guard let writer = CGImageDestinationCreateWithData(
                output, UTType.jpeg.identifier as CFString, 1, nil
            ) else { return nil }
            CGImageDestinationAddImage(
                writer, image,
                [kCGImageDestinationLossyCompressionQuality: 0.76] as CFDictionary
            )
            guard CGImageDestinationFinalize(writer) else { return nil }
            if output.length > 0 && output.length <= 256 * 1_024 {
                return output as Data
            }
        }
        return nil
    }
}
