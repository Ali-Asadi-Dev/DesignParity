/// An 8-bit RGBA image in row-major order, not premultiplied.
public struct RGBAImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width >= 0 && height >= 0 && pixels.count == width * height * 4, "pixel buffer does not match size")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// A solid image.
    public init(width: Int, height: Int, fill: RGBA = .white) {
        self.width = width
        self.height = height
        self.pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4] = fill.r
            pixels[i * 4 + 1] = fill.g
            pixels[i * 4 + 2] = fill.b
            pixels[i * 4 + 3] = fill.a
        }
    }

    public subscript(x: Int, y: Int) -> RGBA {
        get {
            let i = (y * width + x) * 4
            return RGBA(pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
        }
        set {
            let i = (y * width + x) * 4
            pixels[i] = newValue.r
            pixels[i + 1] = newValue.g
            pixels[i + 2] = newValue.b
            pixels[i + 3] = newValue.a
        }
    }

    /// Fills a rectangle, clipped to the image.
    public mutating func fill(_ rect: PixelRect, with color: RGBA) {
        let clipped = rect.clipped(width: width, height: height)
        guard !clipped.isEmpty else { return }
        for y in clipped.y..<(clipped.y + clipped.height) {
            for x in clipped.x..<(clipped.x + clipped.width) { self[x, y] = color }
        }
    }

    public func cropped(to rect: PixelRect) -> RGBAImage {
        let r = rect.clipped(width: width, height: height)
        var out = [UInt8](repeating: 0, count: r.width * r.height * 4)
        for row in 0..<r.height {
            let source = ((r.y + row) * width + r.x) * 4
            let target = row * r.width * 4
            out.replaceSubrange(target..<(target + r.width * 4), with: pixels[source..<(source + r.width * 4)])
        }
        return RGBAImage(width: r.width, height: r.height, pixels: out)
    }

    /// Bilinear resize. Downscaling by more than 2x first box-filters, so thin text stays visible.
    public func resized(width newWidth: Int, height newHeight: Int) -> RGBAImage {
        guard newWidth > 0, newHeight > 0 else { return RGBAImage(width: 0, height: 0, pixels: []) }
        if newWidth == width && newHeight == height { return self }
        var source = self
        while source.width >= newWidth * 2 && source.height >= newHeight * 2 {
            source = source.halved()
        }
        var out = [UInt8](repeating: 0, count: newWidth * newHeight * 4)
        let sx = Double(source.width) / Double(newWidth)
        let sy = Double(source.height) / Double(newHeight)
        for y in 0..<newHeight {
            let fy = max(0, (Double(y) + 0.5) * sy - 0.5)
            let y0 = min(Int(fy), source.height - 1)
            let y1 = min(y0 + 1, source.height - 1)
            let ty = fy - Double(y0)
            for x in 0..<newWidth {
                let fx = max(0, (Double(x) + 0.5) * sx - 0.5)
                let x0 = min(Int(fx), source.width - 1)
                let x1 = min(x0 + 1, source.width - 1)
                let tx = fx - Double(x0)
                for c in 0..<4 {
                    let p00 = Double(source.pixels[(y0 * source.width + x0) * 4 + c])
                    let p10 = Double(source.pixels[(y0 * source.width + x1) * 4 + c])
                    let p01 = Double(source.pixels[(y1 * source.width + x0) * 4 + c])
                    let p11 = Double(source.pixels[(y1 * source.width + x1) * 4 + c])
                    let top = p00 + (p10 - p00) * tx
                    let bottom = p01 + (p11 - p01) * tx
                    out[(y * newWidth + x) * 4 + c] = UInt8(max(0, min(255, (top + (bottom - top) * ty).rounded())))
                }
            }
        }
        return RGBAImage(width: newWidth, height: newHeight, pixels: out)
    }

    /// 2x2 box filter.
    func halved() -> RGBAImage {
        let w = width / 2, h = height / 2
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<4 {
                    let a = Int(pixels[((2 * y) * width + 2 * x) * 4 + c])
                    let b = Int(pixels[((2 * y) * width + 2 * x + 1) * 4 + c])
                    let d = Int(pixels[((2 * y + 1) * width + 2 * x) * 4 + c])
                    let e = Int(pixels[((2 * y + 1) * width + 2 * x + 1) * 4 + c])
                    out[(y * w + x) * 4 + c] = UInt8((a + b + d + e + 2) / 4)
                }
            }
        }
        return RGBAImage(width: w, height: h, pixels: out)
    }
}

public struct RGBA: Equatable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8, a: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let white = RGBA(255, 255, 255)
    public static let black = RGBA(0, 0, 0)
    public static let red = RGBA(255, 0, 0)
}

/// An integer rectangle in pixels, origin at the top left.
public struct PixelRect: Equatable, Hashable, Codable, Sendable {
    public var x: Int, y: Int, width: Int, height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var area: Int { max(0, width) * max(0, height) }

    public func clipped(width w: Int, height h: Int) -> PixelRect {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(w, maxX), y1 = min(h, maxY)
        return PixelRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    public func union(_ other: PixelRect) -> PixelRect {
        let x0 = min(x, other.x), y0 = min(y, other.y)
        return PixelRect(x: x0, y: y0, width: max(maxX, other.maxX) - x0, height: max(maxY, other.maxY) - y0)
    }

    /// Whether the rectangles overlap or are within `gap` pixels of each other.
    public func isNear(_ other: PixelRect, gap: Int) -> Bool {
        x <= other.maxX + gap && other.x <= maxX + gap && y <= other.maxY + gap && other.y <= maxY + gap
    }
}
