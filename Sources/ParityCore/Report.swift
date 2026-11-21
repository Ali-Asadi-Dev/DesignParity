import Foundation

public struct ReportRegion: Equatable, Codable, Sendable {
    /// In points from the top left of the screen.
    public var rect: PointRect
    public var differentPixels: Int
}

/// The result of a comparison, written as JSON for tools and Markdown for people and agents.
public struct Report: Codable, Sendable {
    public var similarity: Double
    public var passThreshold: Double
    public var differentPixels: Int
    public var comparedSize: PixelSize
    public var scale: Double
    public var regions: [ReportRegion]
    public var textFindings: [TextFinding]
    public var notes: [String]
    /// Not encoded: used to draw the overlay.
    public var diffMask: [Bool] = []

    /// Passes only when nothing visible differs: no differing area, no missing or changed text,
    /// and the pixel similarity is above the threshold.
    public var passed: Bool {
        regions.isEmpty && similarity >= passThreshold && !textFindings.contains { $0.kind == .missing || $0.kind == .changed }
    }

    enum CodingKeys: String, CodingKey {
        case similarity, passThreshold, differentPixels, comparedSize, scale, regions, textFindings, notes, passed
    }

    public init(similarity: Double, passThreshold: Double, differentPixels: Int, comparedSize: PixelSize, scale: Double,
                regions: [ReportRegion], textFindings: [TextFinding], notes: [String], diffMask: [Bool]) {
        self.similarity = similarity
        self.passThreshold = passThreshold
        self.differentPixels = differentPixels
        self.comparedSize = comparedSize
        self.scale = scale
        self.regions = regions
        self.textFindings = textFindings
        self.notes = notes
        self.diffMask = diffMask
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        similarity = try c.decode(Double.self, forKey: .similarity)
        passThreshold = try c.decode(Double.self, forKey: .passThreshold)
        differentPixels = try c.decode(Int.self, forKey: .differentPixels)
        comparedSize = try c.decode(PixelSize.self, forKey: .comparedSize)
        scale = try c.decode(Double.self, forKey: .scale)
        regions = try c.decode([ReportRegion].self, forKey: .regions)
        textFindings = try c.decode([TextFinding].self, forKey: .textFindings)
        notes = try c.decode([String].self, forKey: .notes)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(similarity, forKey: .similarity)
        try c.encode(passThreshold, forKey: .passThreshold)
        try c.encode(differentPixels, forKey: .differentPixels)
        try c.encode(comparedSize, forKey: .comparedSize)
        try c.encode(scale, forKey: .scale)
        try c.encode(regions, forKey: .regions)
        try c.encode(textFindings, forKey: .textFindings)
        try c.encode(notes, forKey: .notes)
        try c.encode(passed, forKey: .passed)
    }

    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }

    /// A short, actionable summary. Written for coding agents as much as for people:
    /// every line says where (in points) and what to change.
    public func markdown(maxRegions: Int = 20) -> String {
        var lines: [String] = []
        let percent = String(format: "%.2f%%", similarity * 100)
        let headline = passed ? "✅ Matches the design" : "❌ Differs from the design: \(regions.count) area\(regions.count == 1 ? "" : "s")"
        lines.append("## \(headline) — \(percent) of pixels match")
        lines.append("")
        lines.append(String(format: "Compared %d×%d px at %.0fx (pass threshold %.1f%%).",
                            comparedSize.width, comparedSize.height, scale, passThreshold * 100))
        for note in notes { lines.append("\n> \(note)") }

        if !textFindings.isEmpty {
            lines.append("\n### Text")
            // Texts that moved by the same amount moved together (a whole section shifted):
            // one line for the group says more than one line per label.
            let groups = Self.movedGroups(textFindings)
            var reportedGroup = Set<Int>()
            for (index, f) in textFindings.enumerated() {
                let at = f.designPoint.map { String(format: " at (%.0f, %.0f) pt", $0.x, $0.y) } ?? ""
                if let group = groups.first(where: { $0.contains(index) }) {
                    guard reportedGroup.insert(group[0]).inserted else { continue }
                    let names = group.prefix(3).map { "“\(textFindings[$0].expected ?? "")”" }.joined(separator: ", ")
                    let more = group.count > 3 ? " and \(group.count - 3) more" : ""
                    let top = textFindings[group[0]].designPoint.map { String(format: " from y %.0f pt", $0.y) } ?? ""
                    lines.append("- **Moved together** (\(group.count) texts\(top)): \(Self.direction(f.offset ?? Point(x: 0, y: 0))). \(names)\(more).")
                    continue
                }
                switch f.kind {
                case .missing:
                    lines.append("- **Missing** “\(f.expected ?? "")”\(at).")
                case .unexpected:
                    lines.append("- **Not in the design**: “\(f.actual ?? "")”\(at).")
                case .changed:
                    lines.append("- **Different text**\(at): expected “\(f.expected ?? "")”, found “\(f.actual ?? "")”.")
                case .moved:
                    let o = f.offset ?? Point(x: 0, y: 0)
                    lines.append("- **Moved** “\(f.expected ?? "")”\(at): \(Self.direction(o)).")
                case .resized:
                    let ratio = f.sizeRatio ?? 1
                    let percent = String(format: "%.0f%%", ratio * 100)
                    lines.append("- **Text size** of “\(f.expected ?? "")”\(at): \(percent) of the design (\(ratio > 1 ? "too large" : "too small")).")
                }
            }
        }

        if !regions.isEmpty {
            lines.append("\n### Areas that differ (top to bottom)")
            for (index, region) in regions.prefix(maxRegions).enumerated() {
                let r = region.rect
                lines.append(String(format: "%d. x %.0f–%.0f, y %.0f–%.0f pt (%.0f×%.0f pt)",
                                    index + 1, r.x, r.x + r.width, r.y, r.y + r.height, r.width, r.height))
            }
            if regions.count > maxRegions { lines.append("…and \(regions.count - maxRegions) more further down.") }
        }
        if regions.isEmpty && textFindings.isEmpty { lines.append("\nNo differences found.") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Indices of moved texts that share an offset (within 2 pt), in groups of 3 or more.
    static func movedGroups(_ findings: [TextFinding]) -> [[Int]] {
        var groups: [[Int]] = []
        for (index, f) in findings.enumerated() where f.kind == .moved {
            guard let o = f.offset else { continue }
            if let g = groups.firstIndex(where: { group in
                let first = findings[group[0]].offset!
                return abs(first.x - o.x) <= 2 && abs(first.y - o.y) <= 2
            }) {
                groups[g].append(index)
            } else {
                groups.append([index])
            }
        }
        return groups.filter { $0.count >= 3 }
    }

    static func direction(_ offset: Point) -> String {
        var parts: [String] = []
        if offset.x != 0 { parts.append("\(Int(abs(offset.x))) pt too far \(offset.x > 0 ? "right" : "left")") }
        if offset.y != 0 { parts.append("\(Int(abs(offset.y))) pt too \(offset.y > 0 ? "low" : "high")") }
        return parts.isEmpty ? "in place" : parts.joined(separator: ", ")
    }
}

public enum Overlay {
    /// The app screenshot faded, with differing pixels in red and each region outlined, so the
    /// image shows at a glance where to look.
    public static func render(actual: RGBAImage, report: Report) -> RGBAImage {
        let width = report.comparedSize.width, height = report.comparedSize.height
        var out = actual.resized(width: width, height: Int((Double(actual.height) * Double(width) / Double(max(actual.width, 1))).rounded()))
        if out.height > height { out = out.cropped(to: PixelRect(x: 0, y: 0, width: width, height: height)) }
        // Fade.
        for i in stride(from: 0, to: out.pixels.count, by: 4) {
            for c in 0..<3 { out.pixels[i + c] = UInt8(255 - (255 - Int(out.pixels[i + c])) * 35 / 100) }
        }
        if report.diffMask.count == width * height {
            for y in 0..<out.height {
                for x in 0..<width where report.diffMask[y * width + x] { out[x, y] = RGBA(230, 30, 50) }
            }
        }
        let stroke = max(2, Int(report.scale.rounded()))
        for region in report.regions {
            let r = region.rect.pixels(scale: report.scale)
            let color = RGBA(91, 75, 219)
            out.fill(PixelRect(x: r.x, y: r.y, width: r.width, height: stroke), with: color)
            out.fill(PixelRect(x: r.x, y: r.maxY - stroke, width: r.width, height: stroke), with: color)
            out.fill(PixelRect(x: r.x, y: r.y, width: stroke, height: r.height), with: color)
            out.fill(PixelRect(x: r.maxX - stroke, y: r.y, width: stroke, height: r.height), with: color)
        }
        return out
    }
}
