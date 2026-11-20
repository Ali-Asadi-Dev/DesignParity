import Foundation

/// Compares an implemented screen with its design and produces a report.
public enum Comparison {
    public struct Options: Sendable {
        /// Pixel color threshold, see `PixelDiff.Options`.
        public var threshold: Double = 0.1
        /// Ignore this many points at the top (the status bar's clock and battery always differ).
        public var ignoreTopPoints: Double = 0
        /// Ignore this many points at the bottom (home indicator).
        public var ignoreBottomPoints: Double = 0
        /// Extra areas to ignore, in points (dynamic content such as dates or avatars).
        public var ignoredAreas: [PointRect] = []
        /// Screen width in points; the design image's pixel width divided by this is its scale.
        public var screenWidthPoints: Double = 393
        /// The minimum share of matching pixels (0…1). A screen can match 98% of pixels and
        /// still miss a label, so any remaining differing area also fails the check.
        public var passThreshold: Double = 0.995
        /// Differing areas smaller than this (in square points) are treated as rendering noise.
        public var minimumAreaPoints: Double = 4

        public init() {}
    }

    /// - Parameters:
    ///   - design: the design image (for example a Figma frame exported at 3x).
    ///   - actual: the screenshot of the running app. It is scaled to the design's width.
    ///   - designText / actualText: text on each screen, if known (Figma layers, OCR).
    public static func run(
        design: RGBAImage,
        actual: RGBAImage,
        designText: [TextBox]? = nil,
        actualText: [TextBox]? = nil,
        options: Options = Options()
    ) -> Report {
        let scale = Double(design.width) / options.screenWidthPoints
        var notes: [String] = []

        // Align: scale the screenshot to the design's width, then compare the common height.
        let scaledHeight = Int((Double(actual.height) * Double(design.width) / Double(max(actual.width, 1))).rounded())
        var aligned = actual.resized(width: design.width, height: scaledHeight)
        let designAspect = Double(design.height) / Double(max(design.width, 1))
        let actualAspect = Double(actual.height) / Double(max(actual.width, 1))
        if abs(designAspect - actualAspect) / designAspect > 0.02 {
            notes.append(String(format: "Screen shapes differ: the design is %.0f×%.0f pt, the app screen is %.0f×%.0f pt after scaling to the same width. Only the common area is compared.",
                                options.screenWidthPoints, Double(design.height) / scale,
                                options.screenWidthPoints, Double(scaledHeight) / scale))
        }
        let height = min(design.height, aligned.height)
        var designImage = design.height == height ? design : design.cropped(to: PixelRect(x: 0, y: 0, width: design.width, height: height))
        if aligned.height != height { aligned = aligned.cropped(to: PixelRect(x: 0, y: 0, width: design.width, height: height)) }

        // Mask ignored areas identically in both images so they cannot differ.
        var ignored: [PixelRect] = []
        if options.ignoreTopPoints > 0 {
            ignored.append(PixelRect(x: 0, y: 0, width: design.width, height: Int((options.ignoreTopPoints * scale).rounded())))
        }
        if options.ignoreBottomPoints > 0 {
            let h = Int((options.ignoreBottomPoints * scale).rounded())
            ignored.append(PixelRect(x: 0, y: height - h, width: design.width, height: h))
        }
        ignored += options.ignoredAreas.map { $0.pixels(scale: scale) }
        for rect in ignored {
            designImage.fill(rect, with: .white)
            aligned.fill(rect, with: .white)
        }

        let diff = PixelDiff.compare(designImage, aligned, options: .init(threshold: options.threshold))
        // Group in point units so results don't depend on the export scale: ~3 pt cells,
        // fragments within 8 pt merge (one moved section is one region, not ten).
        let cell = max(2, Int((3 * scale).rounded()))
        let gap = Int((8 * scale).rounded())
        let minPixels = max(1, Int((options.minimumAreaPoints * scale * scale).rounded()))
        let regions = Regions.find(in: diff, cell: cell, gap: gap, minPixels: minPixels)
            .map { ReportRegion(rect: PointRect(pixels: $0.rect, scale: scale), differentPixels: $0.differentPixels) }
            .sorted { ($0.rect.y, $0.rect.x) < ($1.rect.y, $1.rect.x) } // top to bottom, as a person reads

        var textFindings: [TextFinding] = []
        if let designText, let actualText {
            let ignoredNormalized = ignored.map {
                NormalizedRect(x: Double($0.x) / Double(design.width), y: Double($0.y) / Double(height),
                               width: Double($0.width) / Double(design.width), height: Double($0.height) / Double(height))
            }
            func visible(_ box: TextBox) -> Bool {
                !ignoredNormalized.contains { r in box.rect.midY >= r.y && box.rect.midY <= r.y + r.height && box.rect.midX >= r.x && box.rect.midX <= r.x + r.width }
            }
            var textOptions = TextDiff.Options(screenWidth: options.screenWidthPoints, screenHeight: Double(height) / scale)
            textOptions.positionTolerance = 4
            textFindings = TextDiff.compare(design: designText.filter(visible), actual: actualText.filter(visible), options: textOptions)
        }

        return Report(
            similarity: diff.similarity,
            passThreshold: options.passThreshold,
            differentPixels: diff.differentPixels,
            comparedSize: PixelSize(width: design.width, height: height),
            scale: scale,
            regions: regions,
            textFindings: textFindings,
            notes: notes,
            diffMask: diff.mask
        )
    }
}

/// A rectangle in points, origin at the top left.
public struct PointRect: Equatable, Codable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(pixels: PixelRect, scale: Double) {
        x = (Double(pixels.x) / scale).rounded()
        y = (Double(pixels.y) / scale).rounded()
        width = (Double(pixels.width) / scale).rounded()
        height = (Double(pixels.height) / scale).rounded()
    }

    func pixels(scale: Double) -> PixelRect {
        PixelRect(x: Int((x * scale).rounded()), y: Int((y * scale).rounded()),
                  width: Int((width * scale).rounded()), height: Int((height * scale).rounded()))
    }
}

public struct PixelSize: Equatable, Codable, Sendable {
    public var width: Int, height: Int
}
