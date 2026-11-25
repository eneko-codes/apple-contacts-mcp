import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a contact's stored photo into an image a result may carry.
///
/// Contacts keeps whatever was dropped on a card, at whatever size: a photo straight from
/// a camera runs to megabytes, and base64 makes it a third larger again. An image block is
/// not text, so the guard behind every result does not shorten it; the bound has to be
/// here. The photo is redrawn no larger than `longestSide` and encoded as JPEG no heavier
/// than `longestBytes`, and one that cannot be brought under both is not returned at all.
enum ContactPhoto {

    /// The longest side a photo is reduced to, in pixels. A model reading a portrait gains
    /// nothing from more, and the encoded size is what the client has to carry.
    static let longestSide = 1568

    /// The heaviest JPEG a result carries, before base64.
    static let longestBytes = 1_500_000

    /// An interlaced PNG has to be decoded whole to be reduced, so a small file can still
    /// need gigabytes. The pixel count comes from the header, before any decoding.
    static let maximumPixels = 100_000_000

    /// `nil` when `data` is not an image this Mac can decode, holds more pixels than it is
    /// safe to decode, or cannot be encoded within `longestBytes`.
    static func reduced(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maximumPixels else { return nil }

        // "Always", so the reduction is made from the full image and not from a smaller
        // preview the file may embed; "with transform", so a photo stored sideways with an
        // orientation tag comes out upright, since the JPEG below carries no tag.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
            let opaque = flattened(image)
        else { return nil }
        return jpeg(of: opaque)
    }

    /// The first encoding, from the best quality down, that fits `longestBytes`.
    private static func jpeg(of image: CGImage) -> Data? {
        for quality in [0.8, 0.6, 0.4, 0.25] {
            let output = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    output, UTType.jpeg.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(
                destination, image,
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if output.length <= longestBytes { return output as Data }
        }
        return nil
    }

    /// Drawn onto white, because JPEG has no transparency and a cut-out portrait would
    /// otherwise come out on black.
    private static func flattened(_ image: CGImage) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage()
    }
}
