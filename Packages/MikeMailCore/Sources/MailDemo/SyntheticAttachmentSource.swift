import Foundation
import CoreGraphics
import CoreText
import ImageIO
import MailApplication

/// Explicitly labelled local fixtures. No real provider or recipient is involved.
public struct SyntheticAttachmentSource: AttachmentSource {
    public init() {}
    public func download(_ request: AttachmentRequest, sink: @escaping AttachmentSink,
                         progress: @escaping AttachmentProgress) async throws {
        let bytes = try Self.contents(mimeType: request.attachment.mimeType)
        await progress(0, Int64(bytes.count))
        try await AttachmentSafety.writeChunks(bytes, sink: sink)
        await progress(Int64(bytes.count), Int64(bytes.count))
    }
    public static func contents(mimeType: String) throws -> Data {
        let output = NSMutableData()
        if mimeType == "image/png" {
            guard let context = CGContext(data: nil, width: 480, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AttachmentFailure.invalidData }
            context.setFillColor(CGColor(red: 0.1, green: 0.14, blue: 0.15, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 480, height: 240))
            drawLabel(in: context)
            guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)
            else { throw AttachmentFailure.invalidData }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw AttachmentFailure.invalidData }
        } else if mimeType == "application/pdf" {
            var box = CGRect(x: 0, y: 0, width: 480, height: 240)
            guard let consumer = CGDataConsumer(data: output), let context = CGContext(consumer: consumer, mediaBox: &box, nil)
            else { throw AttachmentFailure.invalidData }
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
            drawLabel(in: context); context.endPDFPage(); context.closePDF()
        } else { return Data("Synthetischer Testanhang. Kein Originaldokument.\n".utf8) }
        return output as Data
    }
    private static func drawLabel(in context: CGContext) {
        let text = NSAttributedString(string: "SYNTHETISCHER TESTANHANG\nKein Originaldokument.", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 17, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.67, green: 0.4, blue: 0.15, alpha: 1)])
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: CGRect(x: 24, y: 40, width: 430, height: 160), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: text.length), path, nil), context)
    }
}
