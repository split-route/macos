import AppKit
import CoreImage
import Foundation
import ImageIO
import Vision

/// Reads QR codes out of pictures, for adding servers from a screenshot, a photo or a copied image. The text of a code is
/// handed to the same checks as pasted text (the service parses links; a subscription address is checked as usual).
enum QRReader {
    /// Largest picture read, in bytes: a QR code doesn't need more, and a huge file shouldn't stall the window.
    static let maxBytes = 20 << 20

    /// The text of every QR code in the image.
    static func payloads(in image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    /// The text of every QR code in the picture file at `url`.
    static func payloads(from url: URL) -> [String] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= maxBytes, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return [] }
        return payloads(in: image)
    }

    /// The text of every QR code in an image on the pasteboard (a screenshot copied with Control, say).
    static func payloads(from pasteboard: NSPasteboard) -> [String] {
        guard let image = NSImage(pasteboard: pasteboard), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        return payloads(in: cg)
    }

    /// A QR code of `text` as an image (the tests make one to read back).
    static func code(_ text: String, scale: CGFloat = 8) -> CGImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        return CIContext().createCGImage(out, from: out.extent)
    }
}
