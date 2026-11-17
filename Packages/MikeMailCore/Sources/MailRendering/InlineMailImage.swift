import Foundation
import ImageIO

/// Bounded raster data from this message's MIME parts; never SVG or another document.
public struct InlineMailImage: Sendable, Hashable {
    public static let maximumBytes = 512 * 1024
    public static let maximumTotalBytes = 2 * 1024 * 1024
    public static let maximumCount = 12
    public let data: Data
    public let mimeType: String
    public init?(data: Data) {
        guard !data.isEmpty, data.count <= Self.maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let mime = ["public.png": "image/png", "public.jpeg": "image/jpeg", "com.compuserve.gif": "image/gif", "org.webmproject.webp": "image/webp"][type],
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192,
              CGImageSourceGetCount(source) <= 120,
              width * height * max(1, CGImageSourceGetCount(source)) <= 24_000_000 else { return nil }
        self.data = data; mimeType = mime
    }
    public var dataURI: String { "data:" + mimeType + ";base64," + data.base64EncodedString() }
    static func dataURI(_ raw: String) -> InlineMailImage? {
        guard raw.utf8.count <= maximumBytes * 2, raw.lowercased().hasPrefix("data:image/"),
              let comma = raw.firstIndex(of: ","), raw[..<comma].lowercased().hasSuffix(";base64"),
              let bytes = Data(base64Encoded: String(raw[raw.index(after: comma)...])) else { return nil }
        return InlineMailImage(data: bytes)
    }
    public static func contentID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard !value.isEmpty, value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) else { return nil }
        return value
    }
    public static func supports(_ mime: String) -> Bool {
        ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime.lowercased().components(separatedBy: ";")[0])
    }
}
