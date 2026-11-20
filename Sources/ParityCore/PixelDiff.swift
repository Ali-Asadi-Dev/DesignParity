/// Perceptual pixel comparison.
///
/// A Swift port of the algorithm used by `pixelmatch` (ISC license, Mapbox): colors are
/// compared in the YIQ space, which weighs differences the way people notice them, and
/// anti-aliased edge pixels are detected and ignored, so a 1-pixel font-smoothing difference
/// between Figma's renderer and iOS does not count as a mismatch.
public enum PixelDiff {
    public struct Options: Sendable {
        /// 0…1; smaller is stricter. 0.1 is pixelmatch's default.
        public var threshold: Double = 0.1
        /// Count anti-aliased pixels as differences.
        public var includeAntiAliasing = false

        public init(threshold: Double = 0.1, includeAntiAliasing: Bool = false) {
            self.threshold = threshold
            self.includeAntiAliasing = includeAntiAliasing
        }
    }

    public struct Result: Sendable {
        /// `true` where the pixel differs (row-major, width × height).
        public var mask: [Bool]
        public var differentPixels: Int
        public var antiAliasedPixels: Int
        public var width: Int
        public var height: Int

        public var totalPixels: Int { width * height }
        /// Share of pixels that match, 0…1.
        public var similarity: Double { totalPixels == 0 ? 1 : 1 - Double(differentPixels) / Double(totalPixels) }
    }

    /// Compares two images of the same size.
    public static func compare(_ a: RGBAImage, _ b: RGBAImage, options: Options = Options()) -> Result {
        precondition(a.width == b.width && a.height == b.height, "images must be the same size")
        let width = a.width, height = a.height
        // Maximum acceptable squared YIQ distance (35215 is the largest possible).
        let maxDelta = 35215 * options.threshold * options.threshold
        var mask = [Bool](repeating: false, count: width * height)
        var different = 0
        var antiAliased = 0
        let pa = a.pixels, pb = b.pixels

        for y in 0..<height {
            for x in 0..<width {
                let pos = (y * width + x) * 4
                // Fast path: identical bytes.
                if pa[pos] == pb[pos] && pa[pos + 1] == pb[pos + 1] && pa[pos + 2] == pb[pos + 2] && pa[pos + 3] == pb[pos + 3] {
                    continue
                }
                let delta = colorDelta(pa, pb, pos, pos, yOnly: false)
                guard abs(delta) > maxDelta else { continue }
                if !options.includeAntiAliasing
                    && (isAntiAliased(pa, x, y, width, height, pb) || isAntiAliased(pb, x, y, width, height, pa)) {
                    antiAliased += 1
                } else {
                    mask[y * width + x] = true
                    different += 1
                }
            }
        }
        return Result(mask: mask, differentPixels: different, antiAliasedPixels: antiAliased, width: width, height: height)
    }

    // MARK: - pixelmatch internals

    /// Squared YIQ distance between two pixels, blended over white. The sign tells whether
    /// the pixel got lighter or darker; `yOnly` returns the brightness difference alone.
    static func colorDelta(_ img1: [UInt8], _ img2: [UInt8], _ k: Int, _ m: Int, yOnly: Bool) -> Double {
        var r1 = Double(img1[k]), g1 = Double(img1[k + 1]), b1 = Double(img1[k + 2])
        let a1 = Double(img1[k + 3])
        var r2 = Double(img2[m]), g2 = Double(img2[m + 1]), b2 = Double(img2[m + 2])
        let a2 = Double(img2[m + 3])

        if a1 == a2 && r1 == r2 && g1 == g2 && b1 == b2 { return 0 }

        if a1 < 255 {
            let alpha = a1 / 255
            r1 = blend(r1, alpha); g1 = blend(g1, alpha); b1 = blend(b1, alpha)
        }
        if a2 < 255 {
            let alpha = a2 / 255
            r2 = blend(r2, alpha); g2 = blend(g2, alpha); b2 = blend(b2, alpha)
        }

        let y1 = rgb2y(r1, g1, b1), y2 = rgb2y(r2, g2, b2)
        let y = y1 - y2
        if yOnly { return y }
        let i = rgb2i(r1, g1, b1) - rgb2i(r2, g2, b2)
        let q = rgb2q(r1, g1, b1) - rgb2q(r2, g2, b2)
        let delta = 0.5053 * y * y + 0.299 * i * i + 0.1957 * q * q
        return y1 > y2 ? -delta : delta
    }

    /// Whether the pixel looks like part of an anti-aliased edge: it sits between a darker and
    /// a lighter neighbour, and one of those belongs to a flat area in both images.
    static func isAntiAliased(_ img: [UInt8], _ x1: Int, _ y1: Int, _ width: Int, _ height: Int, _ img2: [UInt8]) -> Bool {
        let x0 = max(x1 - 1, 0), y0 = max(y1 - 1, 0)
        let x2 = min(x1 + 1, width - 1), y2 = min(y1 + 1, height - 1)
        let pos = (y1 * width + x1) * 4
        var zeroes = (x1 == x0 || x1 == x2 || y1 == y0 || y1 == y2) ? 1 : 0
        var minDelta = 0.0, maxDelta = 0.0
        var minX = 0, minY = 0, maxX = 0, maxY = 0

        for x in x0...x2 {
            for y in y0...y2 {
                if x == x1 && y == y1 { continue }
                let delta = colorDelta(img, img, pos, (y * width + x) * 4, yOnly: true)
                if delta == 0 {
                    zeroes += 1
                    if zeroes > 2 { return false }
                } else if delta < minDelta {
                    minDelta = delta; minX = x; minY = y
                } else if delta > maxDelta {
                    maxDelta = delta; maxX = x; maxY = y
                }
            }
        }
        if minDelta == 0 || maxDelta == 0 { return false }
        return (hasManySiblings(img, minX, minY, width, height) && hasManySiblings(img2, minX, minY, width, height))
            || (hasManySiblings(img, maxX, maxY, width, height) && hasManySiblings(img2, maxX, maxY, width, height))
    }

    /// Whether at least 3 neighbours have exactly the same color.
    static func hasManySiblings(_ img: [UInt8], _ x1: Int, _ y1: Int, _ width: Int, _ height: Int) -> Bool {
        let x0 = max(x1 - 1, 0), y0 = max(y1 - 1, 0)
        let x2 = min(x1 + 1, width - 1), y2 = min(y1 + 1, height - 1)
        let pos = (y1 * width + x1) * 4
        var zeroes = (x1 == x0 || x1 == x2 || y1 == y0 || y1 == y2) ? 1 : 0
        for x in x0...x2 {
            for y in y0...y2 {
                if x == x1 && y == y1 { continue }
                let pos2 = (y * width + x) * 4
                if img[pos] == img[pos2] && img[pos + 1] == img[pos2 + 1] && img[pos + 2] == img[pos2 + 2] && img[pos + 3] == img[pos2 + 3] {
                    zeroes += 1
                }
                if zeroes > 2 { return true }
            }
        }
        return false
    }

    static func blend(_ c: Double, _ a: Double) -> Double { 255 + (c - 255) * a }
    static func rgb2y(_ r: Double, _ g: Double, _ b: Double) -> Double { r * 0.29889531 + g * 0.58662247 + b * 0.11448223 }
    static func rgb2i(_ r: Double, _ g: Double, _ b: Double) -> Double { r * 0.59597799 - g * 0.27417610 - b * 0.32180189 }
    static func rgb2q(_ r: Double, _ g: Double, _ b: Double) -> Double { r * 0.21147017 - g * 0.52261711 + b * 0.31114694 }
}
