import XCTest
@testable import Splitroute

final class QRReaderTests: XCTestCase {
    func testReadsBackWhatACodeSays() throws {
        let link = "vless://b831381d-6324-4d53-ad4f-8cda48b30811@example.com:443?security=tls&sni=example.com&type=ws&path=%2Fws#Berlin"
        let image = try XCTUnwrap(QRReader.code(link))
        XCTAssertEqual(QRReader.payloads(in: image), [link])
    }

    func testAPictureWithNoCodeGivesNothing() throws {
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        XCTAssertEqual(QRReader.payloads(in: ctx.makeImage()!), [])
    }
}
