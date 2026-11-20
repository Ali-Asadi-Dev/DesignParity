#if canImport(ImageIO) && canImport(Vision)
import CoreGraphics
import CoreText
import Foundation
import ParityCore
import Testing
@testable import ParityApple

private let examples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples")

/// Renders black text on white, like a simple screen.
private func render(_ lines: [(String, CGFloat)], width: Int = 900, height: Int = 600) throws -> RGBAImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateUIFontForLanguage(.system, 48, nil)!
    for (text, topY) in lines {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 60, y: CGFloat(height) - topY - 48) // Core Graphics origin is bottom left
        CTLineDraw(line, context)
    }
    return try PNG.rgba(from: context.makeImage()!)
}

@Suite struct AppleTests {
    @Test func pngRoundTripsExactly() throws {
        var image = RGBAImage(width: 7, height: 5)
        image[3, 2] = RGBA(91, 75, 219)
        image[6, 4] = RGBA(10, 20, 30)
        #expect(try PNG.decode(PNG.encode(image)) == image)
    }

    @Test func recognizesTextWithTopLeftCoordinates() throws {
        let image = try render([("Per month", 80), ("Get started", 400)])
        let boxes = try TextRecognizer.recognize(image)
        let texts = boxes.map(\.text)
        #expect(texts.contains("Per month"))
        #expect(texts.contains("Get started"))
        let top = try #require(boxes.first { $0.text == "Per month" })
        let bottom = try #require(boxes.first { $0.text == "Get started" })
        #expect(top.rect.y < bottom.rect.y) // y grows downwards
        #expect(abs(top.rect.x - 60.0 / 900) < 0.03)
    }

    @Test func findsThePlantedDifferencesInTheExample() throws {
        let design = try PNG.read(examples.appendingPathComponent("design.png"))
        let actual = try PNG.read(examples.appendingPathComponent("actual.png"))
        var options = Comparison.Options()
        options.screenWidthPoints = 420
        options.ignoreTopPoints = 59
        let report = Comparison.run(design: design, actual: actual,
                                    designText: try TextRecognizer.recognize(design),
                                    actualText: try TextRecognizer.recognize(actual), options: options)
        print(report.markdown())
        #expect(!report.passed)
        // 1. The "6 active subscriptions" label was removed.
        #expect(report.textFindings.contains { $0.kind == .missing && ($0.expected ?? "").contains("active subscriptions") })
        // 2. The "Next 7 days" section is 12 pt lower.
        let moved = report.textFindings.first { $0.kind == .moved && $0.expected == "Next 7 days" }
        #expect(moved?.offset?.y == 12)
        // 3. The avatar color changed: a region around x 40–80, y 405–445 pt.
        #expect(report.regions.contains { $0.rect.y >= 395 && $0.rect.y <= 415 && $0.rect.x < 60 })
    }

    @Test func identicalScreensPass() throws {
        let design = try PNG.read(examples.appendingPathComponent("design.png"))
        var options = Comparison.Options()
        options.screenWidthPoints = 420
        let text = try TextRecognizer.recognize(design)
        let report = Comparison.run(design: design, actual: design, designText: text, actualText: text, options: options)
        #expect(report.passed)
        #expect(report.textFindings.isEmpty)
    }
}
#endif
