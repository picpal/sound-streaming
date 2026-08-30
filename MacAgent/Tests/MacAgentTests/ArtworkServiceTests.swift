import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import MacAgentCore

final class ArtworkServiceTests: XCTestCase {
    /// 256x256 단색 PNG를 인메모리 생성
    private func makePNG(side: Int) -> Data {
        var pixels = [UInt8](repeating: 128, count: side * side * 4)
        let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let img = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    func testResizeCapsLongestSideTo128() throws {
        let resized = try XCTUnwrap(ArtworkService.resizeJPEG(makePNG(side: 256), maxPx: 128))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(resized as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        let w = props[kCGImagePropertyPixelWidth] as? Int
        XCTAssertEqual(w, 128)
        // JPEG로 재인코딩됐는지
        let type = CGImageSourceGetType(src) as String?
        XCTAssertEqual(type, UTType.jpeg.identifier)
    }

    func testResizeRejectsGarbage() {
        XCTAssertNil(ArtworkService.resizeJPEG(Data([0x00, 0x01, 0x02]), maxPx: 128))
    }

    func testUnregisteredIdServesNothing() async {
        let svc = ArtworkService()
        let img = await svc.image(id: "unknown-id")
        XCTAssertNil(img)                          // 등록된 id만 — open proxy 방지
    }

    func testRegisterTrackDerivesYtimgURL() {
        let svc = ArtworkService()
        svc.registerTrack(id: "dQw4w9WgXcQ")
        XCTAssertEqual(svc.registeredURL(id: "dQw4w9WgXcQ"),
                       "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg")
    }
}
