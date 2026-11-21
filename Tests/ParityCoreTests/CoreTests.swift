import Foundation
import Testing
@testable import ParityCore

/// A tiny "screen": white background, a dark title bar and a colored button.
private func screen(width: Int = 120, height: Int = 240, buttonColor: RGBA = RGBA(91, 75, 219), buttonY: Int = 150) -> RGBAImage {
    var image = RGBAImage(width: width, height: height)
    image.fill(PixelRect(x: 10, y: 20, width: 100, height: 12), with: RGBA(20, 20, 30))
    image.fill(PixelRect(x: 20, y: buttonY, width: 80, height: 24), with: buttonColor)
    return image
}

@Suite struct PixelDiffTests {
    @Test func identicalImagesMatchCompletely() {
        let result = PixelDiff.compare(screen(), screen())
        #expect(result.differentPixels == 0)
        #expect(result.similarity == 1)
    }

    @Test func aChangedColorIsCountedExactly() {
        let result = PixelDiff.compare(screen(), screen(buttonColor: RGBA(230, 30, 50)))
        #expect(result.differentPixels == 80 * 24)
        #expect(abs(result.similarity - (1 - 1920.0 / (120 * 240))) < 1e-9)
    }

    @Test func barelyVisibleColorChangesAreBelowTheThreshold() {
        let result = PixelDiff.compare(screen(), screen(buttonColor: RGBA(93, 76, 220)))
        #expect(result.differentPixels == 0)
        let strict = PixelDiff.compare(screen(), screen(buttonColor: RGBA(93, 76, 220)), options: .init(threshold: 0.001))
        #expect(strict.differentPixels == 80 * 24)
    }

    @Test func antiAliasedEdgesAreIgnored() {
        // A sharp edge in one image, the same edge with a one-pixel soft border in the other.
        var a = RGBAImage(width: 40, height: 40)
        var b = RGBAImage(width: 40, height: 40)
        a.fill(PixelRect(x: 10, y: 10, width: 20, height: 20), with: .black)
        b.fill(PixelRect(x: 10, y: 10, width: 20, height: 20), with: .black)
        for y in 10..<30 { b[30, y] = RGBA(128, 128, 128) }
        let result = PixelDiff.compare(a, b)
        #expect(result.differentPixels == 0)
        #expect(result.antiAliasedPixels > 0)
        #expect(PixelDiff.compare(a, b, options: .init(includeAntiAliasing: true)).differentPixels == 20)
    }

    @Test func transparentPixelsAreBlendedOverWhite() {
        let transparent = RGBAImage(width: 4, height: 4, fill: RGBA(0, 0, 0, 0))
        #expect(PixelDiff.compare(transparent, RGBAImage(width: 4, height: 4)).differentPixels == 0)
    }

    @Test func colorDeltaMatchesPixelmatch() {
        // Black vs white differs only in brightness: 0.5053 × 255² ≈ 32857 (sign: the first is darker).
        let black: [UInt8] = [0, 0, 0, 255], white: [UInt8] = [255, 255, 255, 255]
        #expect(abs(PixelDiff.colorDelta(black, white, 0, 0, yOnly: false) - 32857) < 1)
        #expect(PixelDiff.colorDelta(white, black, 0, 0, yOnly: false) < 0)
    }
}

@Suite struct RegionTests {
    @Test func oneChangedElementIsOneRegion() {
        let diff = PixelDiff.compare(screen(), screen(buttonColor: RGBA(230, 30, 50)))
        let regions = Regions.find(in: diff)
        #expect(regions.count == 1)
        #expect(regions[0].differentPixels == 1920)
        // Bounds are cell-aligned around the button (x 20–100, y 150–174).
        #expect(regions[0].rect.x <= 20 && regions[0].rect.maxX >= 100)
        #expect(regions[0].rect.y <= 150 && regions[0].rect.maxY >= 174)
    }

    @Test func farApartChangesStaySeparateAndNoiseIsDropped() {
        var a = RGBAImage(width: 200, height: 200)
        var b = a
        b.fill(PixelRect(x: 5, y: 5, width: 20, height: 20), with: .black)
        b.fill(PixelRect(x: 150, y: 150, width: 30, height: 30), with: .black)
        b[100, 100] = .black // a single stray pixel
        a[0, 199] = .white
        let regions = Regions.find(in: PixelDiff.compare(a, b))
        #expect(regions.count == 2)
        #expect(regions[0].differentPixels == 900) // largest first
        #expect(regions[1].differentPixels == 400)
    }

    @Test func nearbyChangesMerge() {
        let a = RGBAImage(width: 100, height: 100)
        var b = a
        b.fill(PixelRect(x: 10, y: 10, width: 10, height: 10), with: .black)
        b.fill(PixelRect(x: 30, y: 10, width: 10, height: 10), with: .black)
        #expect(Regions.find(in: PixelDiff.compare(a, b), gap: 12).count == 1)
        #expect(Regions.find(in: PixelDiff.compare(a, b), cell: 4, gap: 0).count == 2)
    }
}

@Suite struct ImageTests {
    @Test func resizeKeepsSolidColorsAndSizes() {
        let image = RGBAImage(width: 300, height: 600, fill: RGBA(91, 75, 219))
        let small = image.resized(width: 100, height: 200)
        #expect(small.width == 100 && small.height == 200)
        #expect(small[50, 100] == RGBA(91, 75, 219))
        let up = small.resized(width: 150, height: 300)
        #expect(up[149, 299] == RGBA(91, 75, 219))
    }

    @Test func downscalingKeepsThinLinesVisible() {
        var image = RGBAImage(width: 400, height: 400)
        image.fill(PixelRect(x: 0, y: 200, width: 400, height: 2), with: .black)
        let small = image.resized(width: 100, height: 100)
        let darkest = (0..<100).map { Int(small[50, $0].r) }.min() ?? 255
        #expect(darkest < 200)
    }

    @Test func cropAndClip() {
        var image = RGBAImage(width: 10, height: 10)
        image[3, 4] = .red
        let crop = image.cropped(to: PixelRect(x: 2, y: 3, width: 20, height: 20))
        #expect(crop.width == 8 && crop.height == 7)
        #expect(crop[1, 1] == .red)
    }
}

@Suite struct TextDiffTests {
    private func box(_ text: String, x: Double, y: Double, w: Double = 100, h: Double = 20, size: Double? = nil) -> TextBox {
        // Points on a 400 × 800 screen, normalized.
        TextBox(text: text, rect: NormalizedRect(x: x / 400, y: y / 800, width: w / 400, height: h / 800), fontSize: size)
    }

    private let options = TextDiff.Options(screenWidth: 400, screenHeight: 800)

    @Test func sameTextInPlaceHasNoFindings() {
        let design = [box("Per month", x: 20, y: 100), box("Save", x: 300, y: 40)]
        let actual = [box("PER MONTH", x: 21, y: 101), box("Save.", x: 302, y: 39)]
        #expect(TextDiff.compare(design: design, actual: actual, options: options).isEmpty)
    }

    @Test func findsMovedResizedChangedMissingAndUnexpected() {
        let design = [
            box("Per month", x: 20, y: 100),
            box("Next renewal", x: 20, y: 300),
            box("Free trials ending", x: 20, y: 400),
            box("Get started", x: 20, y: 600),
            box("Total", x: 20, y: 700, h: 20),
        ]
        let actual = [
            box("Per month", x: 20, y: 112),           // 12 pt too low
            box("Next renewl", x: 22, y: 302),         // typo
            box("Settings", x: 20, y: 760),            // not in the design
            box("Total", x: 20, y: 700, h: 30),        // 150% tall
        ]
        let findings = TextDiff.compare(design: design, actual: actual, options: options)
        let kinds = Dictionary(grouping: findings, by: \.kind)
        #expect(kinds[.moved]?.first?.expected == "Per month")
        #expect(kinds[.moved]?.first?.offset == Point(x: 0, y: 12))
        #expect(kinds[.changed]?.first?.actual == "Next renewl")
        #expect(Set(kinds[.missing]?.map { $0.expected ?? "" } ?? []) == ["Free trials ending", "Get started"])
        #expect(kinds[.unexpected]?.first?.actual == "Settings")
        #expect(kinds[.resized]?.first?.sizeRatio == 1.5)
        // Sorted top to bottom.
        #expect(findings.map { $0.designPoint?.y ?? 0 } == findings.map { $0.designPoint?.y ?? 0 }.sorted())
    }

    @Test func smallWobbleOnTheOtherAxisIsNotReported() {
        let findings = TextDiff.compare(design: [box("Netflix", x: 90, y: 540)], actual: [box("Netflix", x: 92, y: 552)], options: options)
        #expect(findings.first?.offset == Point(x: 0, y: 12))
    }

    @Test func textsThatMovedTogetherAreOneLine() {
        func moved(_ text: String, y: Double, dy: Double) -> TextFinding {
            TextFinding(kind: .moved, expected: text, actual: text, designPoint: Point(x: 40, y: y), offset: Point(x: 0, y: dy))
        }
        let findings = [moved("Next 7 days", y: 492, dy: 12), moved("Netflix", y: 540, dy: 13), moved("$15.49", y: 549, dy: 12),
                        moved("Spotify", y: 614, dy: 12), moved("Title", y: 100, dy: -20)]
        let report = Report(similarity: 0.98, passThreshold: 0.995, differentPixels: 1, comparedSize: PixelSize(width: 1, height: 1),
                            scale: 3, regions: [], textFindings: findings, notes: [], diffMask: [])
        let markdown = report.markdown()
        #expect(markdown.contains("**Moved together** (4 texts from y 492 pt): 12 pt too low. “Next 7 days”, “Netflix”, “$15.49” and 1 more."))
        #expect(markdown.contains("**Moved** “Title” at (40, 100) pt: 20 pt too high."))
    }

    @Test func toleratesOcrJoiningLines() {
        let design = [box("$94.76", x: 20, y: 120), box("a year", x: 120, y: 120)]
        let actual = [box("$94.76 a year", x: 20, y: 120, w: 200)]
        #expect(TextDiff.compare(design: design, actual: actual, options: options).isEmpty)
    }

    @Test func toleratesOcrSplittingALine() {
        let design = [box("Add the services you pay for", x: 20, y: 300, w: 300, h: 40)]
        let actual = [box("Add the services", x: 20, y: 300, w: 150), box("you pay for", x: 20, y: 320, w: 100)]
        #expect(TextDiff.compare(design: design, actual: actual, options: options).isEmpty)
    }

    @Test func truncatedTextIsAChangeNotAMatch() {
        let design = [box("Subscriptions", x: 20, y: 300)]
        let actual = [box("Subscripti…", x: 20, y: 300)]
        let findings = TextDiff.compare(design: design, actual: actual, options: options)
        #expect(findings.map(\.kind) == [.changed])
    }

    @Test func similarityIsEditDistanceBased() {
        #expect(TextDiff.similarity("renewal", "renewal") == 1)
        #expect(TextDiff.similarity("renewal", "renewl") > 0.8)
        #expect(TextDiff.similarity("abc", "xyz") == 0)
        #expect(TextDiff.normalize("  Save, Now! ") == "savenow")
        #expect(TextDiff.normalize("۹٫۹۹ دلار") == "۹۹۹دلار")
    }
}

@Suite struct ComparisonTests {
    @Test func scalesTheScreenshotAndIgnoresTheStatusBar() {
        // Design at 3x of a 40 pt wide screen; the screenshot is the same screen at 2x with a
        // different "status bar" (top 10 pt).
        var design = RGBAImage(width: 120, height: 240)
        design.fill(PixelRect(x: 30, y: 120, width: 60, height: 30), with: RGBA(91, 75, 219))
        var actual = RGBAImage(width: 80, height: 160)
        actual.fill(PixelRect(x: 20, y: 80, width: 40, height: 20), with: RGBA(91, 75, 219))
        actual.fill(PixelRect(x: 0, y: 0, width: 80, height: 20), with: .black) // status bar

        var options = Comparison.Options()
        options.screenWidthPoints = 40
        let withStatusBar = Comparison.run(design: design, actual: actual, options: options)
        #expect(!withStatusBar.passed)
        #expect(withStatusBar.regions.first?.rect.y == 0)

        // 1 pt more than the bar: scaling 2x → 3x blurs its bottom edge by a pixel.
        options.ignoreTopPoints = 11
        let report = Comparison.run(design: design, actual: actual, options: options)
        #expect(report.passed, "\(report.markdown())")
        #expect(report.similarity > 0.99)
        #expect(report.scale == 3)
    }

    @Test func reportsRegionsInPointsAndFailsBelowThreshold() {
        var options = Comparison.Options()
        options.screenWidthPoints = 40 // 120 px design → 3x
        let report = Comparison.run(design: screen(), actual: screen(buttonColor: RGBA(230, 30, 50)), options: options)
        #expect(!report.passed)
        let region = report.regions[0].rect
        #expect(region.x <= 7 && region.x + region.width >= 33) // button: x 20–100 px = 6.7–33.3 pt
        #expect(region.y <= 50 && region.y + region.height >= 58)
        let markdown = report.markdown()
        #expect(markdown.contains("❌ Differs from the design"))
        #expect(markdown.contains("### Areas that differ (top to bottom)"))
    }

    @Test func differentShapesAreNotedAndTheCommonAreaCompared() {
        let design = RGBAImage(width: 120, height: 240)
        let actual = RGBAImage(width: 120, height: 300)
        var options = Comparison.Options()
        options.screenWidthPoints = 40
        let report = Comparison.run(design: design, actual: actual, options: options)
        #expect(report.comparedSize == PixelSize(width: 120, height: 240))
        #expect(report.notes.count == 1)
        #expect(report.passed)
    }

    @Test func aSmallMissingElementFailsEvenAt99PercentSimilarity() {
        var design = RGBAImage(width: 300, height: 600)
        design.fill(PixelRect(x: 30, y: 300, width: 60, height: 12), with: .black) // a short label
        var options = Comparison.Options()
        options.screenWidthPoints = 100
        let report = Comparison.run(design: design, actual: RGBAImage(width: 300, height: 600), options: options)
        #expect(report.similarity > 0.99)
        #expect(!report.passed)
        #expect(report.regions.count == 1)
    }

    @Test func textFindingsFailTheCheckAndAppearInMarkdown() {
        var options = Comparison.Options()
        options.screenWidthPoints = 40
        let design = [TextBox(text: "Save", rect: NormalizedRect(x: 0.5, y: 0.6, width: 0.2, height: 0.05))]
        let actual = [TextBox(text: "Sav", rect: NormalizedRect(x: 0.5, y: 0.6, width: 0.2, height: 0.05))]
        let report = Comparison.run(design: screen(), actual: screen(), designText: design, actualText: actual, options: options)
        #expect(report.similarity == 1)
        #expect(!report.passed) // the pixels match but the text does not
        #expect(report.markdown().contains("expected “Save”, found “Sav”"))
        let json = report.json()
        #expect(json.contains("\"passed\" : false"))
        #expect(!json.contains("diffMask"))
    }

    @Test func overlayHighlightsDifferences() {
        var options = Comparison.Options()
        options.screenWidthPoints = 40
        let actual = screen(buttonColor: RGBA(230, 30, 50))
        let report = Comparison.run(design: screen(), actual: actual, options: options)
        let overlay = Overlay.render(actual: actual, report: report)
        #expect(overlay.width == 120 && overlay.height == 240)
        #expect(overlay[60, 160] == RGBA(230, 30, 50)) // inside the changed button
        #expect(overlay[5, 230].r > 200) // faded background stays light
    }
}
