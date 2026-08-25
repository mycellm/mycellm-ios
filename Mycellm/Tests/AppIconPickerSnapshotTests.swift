import XCTest
import SwiftUI
@testable import Mycellm

/// Renders the icon picker and checks its geometry.
///
/// ⚠️ THE FIRST VERSION OF THIS PICKER SHIPPED WITH THREE VISIBLE FAULTS —
/// placeholder circles instead of the real icons, "Light Blue" wrapping onto a
/// second line and breaking row alignment, and variants drawn at the wrong
/// scale inside the squircle. None were caught because nothing rendered it
/// outside a human's eyes. This does.
@MainActor
final class AppIconPickerSnapshotTests: XCTestCase {

    private func render(_ view: some View, width: CGFloat) -> UIImage {
        let host = UIHostingController(rootView: view.frame(width: width).background(Color.voidBlack))
        host.view.bounds = CGRect(x: 0, y: 0, width: width, height: 400)
        host.view.backgroundColor = .black
        let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        host.view.bounds = CGRect(origin: .zero, size: size)
        return UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
    }

    func testEveryPreviewAssetExists() throws {
        // A missing asset renders as an empty box — the picker would look
        // "broken" in exactly the way a placeholder circle did not.
        for option in AppIconOption.allCases {
            XCTAssertNotNil(UIImage(named: option.previewAsset),
                            "missing preview artwork for \(option.label)")
        }
    }

    func testPreviewsAreTheRealIconArtworkNotAFlatSwatch() throws {
        // The artwork has a black background, a coloured cap, an amber stem and
        // white spots. A flat colour tile would have one. Four distinct regions
        // is the cheapest proof the real icon is in there.
        for option in AppIconOption.allCases {
            let image = try XCTUnwrap(UIImage(named: option.previewAsset))
            let colors = Self.distinctColors(in: image)
            XCTAssertGreaterThan(colors, 3,
                "\(option.label) preview looks like a flat swatch (\(colors) colours)")
        }
    }

    func testAllPreviewsShareTheSameArtworkGeometry() throws {
        // The bug: non-red icons were drawn larger in the squircle. Every
        // variant must put its non-background content in the same place.
        var boxes: [CGRect] = []
        for option in AppIconOption.allCases {
            let image = try XCTUnwrap(UIImage(named: option.previewAsset))
            boxes.append(Self.contentBounds(of: image))
        }
        guard let first = boxes.first else { return XCTFail("no previews") }
        for (option, box) in zip(AppIconOption.allCases, boxes) {
            XCTAssertEqual(box.minX, first.minX, accuracy: 2, "\(option.label) x")
            XCTAssertEqual(box.minY, first.minY, accuracy: 2, "\(option.label) y")
            XCTAssertEqual(box.width, first.width, accuracy: 2, "\(option.label) width")
            XCTAssertEqual(box.height, first.height, accuracy: 2, "\(option.label) height")
        }
    }

    func testTheGridFitsAWholeNumberOfCellsWithoutWrappingLabels() {
        // "Light Blue" is the longest label. Render at the narrowest realistic
        // width and assert the picker stays within a two-row height — a wrapped
        // label would push it taller.
        let narrow = render(AppIconPicker(), width: 320)
        XCTAssertLessThan(narrow.size.height, 230,
                          "a wrapped label has pushed the grid taller than two rows")
        XCTAssertGreaterThan(narrow.size.height, 60, "the picker rendered empty")
    }

    // MARK: - Pixel helpers

    private static func pixels(_ image: UIImage) -> (data: [UInt8], w: Int, h: Int)? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (buf, w, h)
    }

    private static func distinctColors(in image: UIImage) -> Int {
        guard let (buf, w, h) = pixels(image) else { return 0 }
        var seen = Set<UInt32>()
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            // Quantise so anti-aliasing does not inflate the count.
            let r = UInt32(buf[i] / 32), g = UInt32(buf[i+1] / 32), b = UInt32(buf[i+2] / 32)
            seen.insert(r << 16 | g << 8 | b)
        }
        return seen.count
    }

    /// Bounding box of everything that is not the near-black background.
    private static func contentBounds(of image: UIImage) -> CGRect {
        guard let (buf, w, h) = pixels(image) else { return .zero }
        var minX = w, minY = h, maxX = 0, maxY = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let bright = Int(buf[i]) + Int(buf[i+1]) + Int(buf[i+2])
                if bright > 90 {           // anything above the #0A0A0A ground
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX else { return .zero }
        // Normalised so previews of different pixel sizes compare directly.
        let sx = CGFloat(w), sy = CGFloat(h)
        return CGRect(x: CGFloat(minX) / sx * 100, y: CGFloat(minY) / sy * 100,
                      width: CGFloat(maxX - minX) / sx * 100,
                      height: CGFloat(maxY - minY) / sy * 100)
    }
}
