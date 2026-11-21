/// A piece of text on screen. `rect` is normalized to the screen: 0…1 on both axes, origin top left.
public struct TextBox: Equatable, Codable, Sendable {
    public var text: String
    public var rect: NormalizedRect
    /// Font size in points when known (Figma knows it; OCR does not).
    public var fontSize: Double?

    public init(text: String, rect: NormalizedRect, fontSize: Double? = nil) {
        self.text = text
        self.rect = rect
        self.fontSize = fontSize
    }
}

public struct NormalizedRect: Equatable, Codable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

/// A difference in the text on screen, with positions in points.
public struct TextFinding: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case missing, unexpected, changed, moved, resized }

    public var kind: Kind
    public var expected: String?
    public var actual: String?
    /// Where it is in the design (points from the top left).
    public var designPoint: Point?
    /// How far the actual text is from where the design puts it, in points (positive = right / down).
    public var offset: Point?
    /// Actual height ÷ design height, when the size differs.
    public var sizeRatio: Double?
}

public struct Point: Equatable, Codable, Sendable {
    public var x: Double, y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Matches the text of the design against the text on screen.
public enum TextDiff {
    public struct Options: Sendable {
        /// Screen size in points, to report positions in points.
        public var screenWidth: Double
        public var screenHeight: Double
        /// Movement below this is ignored (points).
        public var positionTolerance: Double = 4
        /// Height ratios within 1 ± this are ignored.
        public var sizeTolerance: Double = 0.2
        /// Text similarity (0…1) needed to call two strings the same element with changed text.
        public var changedSimilarity: Double = 0.5

        public init(screenWidth: Double, screenHeight: Double) {
            self.screenWidth = screenWidth
            self.screenHeight = screenHeight
        }
    }

    public static func compare(design: [TextBox], actual: [TextBox], options: Options) -> [TextFinding] {
        var unmatched = Array(actual.indices)
        var findings: [TextFinding] = []
        var pending: [Int] = []

        func point(_ rect: NormalizedRect) -> Point {
            Point(x: rect.x * options.screenWidth, y: rect.y * options.screenHeight)
        }
        func distance(_ a: NormalizedRect, _ b: NormalizedRect) -> Double {
            let dx = (a.midX - b.midX) * options.screenWidth, dy = (a.midY - b.midY) * options.screenHeight
            return (dx * dx + dy * dy).squareRoot()
        }
        func compareMatched(_ d: TextBox, _ a: TextBox) {
            let dx = (a.rect.x - d.rect.x) * options.screenWidth
            let dy = (a.rect.y - d.rect.y) * options.screenHeight
            if abs(dx) > options.positionTolerance || abs(dy) > options.positionTolerance {
                // Report only the axis that is really off: OCR boxes wobble by a point or two.
                let x = abs(dx) > options.positionTolerance ? dx.rounded() : 0
                let y = abs(dy) > options.positionTolerance ? dy.rounded() : 0
                findings.append(TextFinding(kind: .moved, expected: d.text, actual: a.text, designPoint: point(d.rect),
                                            offset: Point(x: x, y: y)))
            }
            if d.rect.height > 0 {
                let ratio = a.rect.height / d.rect.height
                if abs(ratio - 1) > options.sizeTolerance {
                    findings.append(TextFinding(kind: .resized, expected: d.text, actual: a.text, designPoint: point(d.rect),
                                                sizeRatio: (ratio * 100).rounded() / 100))
                }
            }
        }

        // 1. Exact (normalized) text matches, nearest first.
        for (di, d) in design.enumerated() {
            let key = normalize(d.text)
            guard !key.isEmpty else { continue }
            let candidates = unmatched.filter { normalize(actual[$0].text) == key }
            if let best = candidates.min(by: { distance(actual[$0].rect, d.rect) < distance(actual[$1].rect, d.rect) }) {
                unmatched.removeAll { $0 == best }
                compareMatched(d, actual[best])
            } else {
                pending.append(di)
            }
        }

        // 2. OCR joins and splits lines differently from the design's text layers.
        var joined = Set<Int>()
        var stillPending: [Int] = []
        for di in pending {
            let d = design[di], key = normalize(d.text)
            // a) The design text is part of a longer recognized line.
            let containing = (unmatched + joined.sorted()).filter {
                normalize(actual[$0].text).contains(key) && contains(actual[$0].rect, d.rect, margin: 20, options)
            }
            if let best = containing.min(by: { distance(actual[$0].rect, d.rect) < distance(actual[$1].rect, d.rect) }) {
                unmatched.removeAll { $0 == best }
                joined.insert(best)
                continue
            }
            // b) The design text was recognized as several pieces that together spell it.
            let pieces = unmatched
                .filter {
                    let other = normalize(actual[$0].text)
                    return !other.isEmpty && key.contains(other) && contains(d.rect, actual[$0].rect, margin: 20, options)
                }
                .sorted { (actual[$0].rect.y, actual[$0].rect.x) < (actual[$1].rect.y, actual[$1].rect.x) }
            if !pieces.isEmpty && pieces.map({ normalize(actual[$0].text) }).joined() == key {
                unmatched.removeAll { pieces.contains($0) }
                continue
            }
            stillPending.append(di)
        }

        // 3. Similar text close by: the element is there but its text changed.
        for di in stillPending {
            let d = design[di]
            let candidates = unmatched.filter {
                similarity(normalize(actual[$0].text), normalize(d.text)) >= options.changedSimilarity
                    && distance(actual[$0].rect, d.rect) < 40
            }
            if let best = candidates.min(by: { distance(actual[$0].rect, d.rect) < distance(actual[$1].rect, d.rect) }) {
                unmatched.removeAll { $0 == best }
                findings.append(TextFinding(kind: .changed, expected: d.text, actual: actual[best].text, designPoint: point(d.rect)))
            } else {
                findings.append(TextFinding(kind: .missing, expected: d.text, designPoint: point(d.rect)))
            }
        }

        for ai in unmatched where !normalize(actual[ai].text).isEmpty {
            findings.append(TextFinding(kind: .unexpected, actual: actual[ai].text, designPoint: point(actual[ai].rect)))
        }
        return findings.sorted { ($0.designPoint?.y ?? 0, $0.designPoint?.x ?? 0) < ($1.designPoint?.y ?? 0, $1.designPoint?.x ?? 0) }
    }

    /// Whether `inner`'s center lies inside `outer` grown by `margin` points.
    static func contains(_ outer: NormalizedRect, _ inner: NormalizedRect, margin: Double, _ options: Options) -> Bool {
        let mx = margin / options.screenWidth, my = margin / options.screenHeight
        return inner.midX >= outer.x - mx && inner.midX <= outer.x + outer.width + mx
            && inner.midY >= outer.y - my && inner.midY <= outer.y + outer.height + my
    }

    /// Case-, space- and punctuation-insensitive form, so OCR quirks don't count as changes.
    static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { scalar in
            scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar.properties.numericType != nil
        }.map(Character.init))
    }

    /// 1 − edit distance ÷ longer length.
    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var current = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        let distance = a.isEmpty ? b.count : (b.isEmpty ? a.count : previous[b.count])
        return 1 - Double(distance) / Double(max(a.count, b.count))
    }
}
