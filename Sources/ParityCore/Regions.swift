/// Groups differing pixels into a few rectangles a person (or an agent) can act on.
public enum Regions {
    /// - Parameters:
    ///   - cell: pixels are bucketed into `cell` × `cell` blocks before grouping, which joins
    ///     the scattered pixels of one changed element and keeps grouping fast.
    ///   - gap: rectangles closer than this many pixels are merged.
    ///   - minPixels: regions with fewer differing pixels are dropped as noise.
    public static func find(in diff: PixelDiff.Result, cell: Int = 8, gap: Int = 12, minPixels: Int = 12) -> [DiffRegion] {
        let cols = (diff.width + cell - 1) / cell
        let rows = (diff.height + cell - 1) / cell
        guard cols > 0, rows > 0 else { return [] }

        var counts = [Int](repeating: 0, count: cols * rows)
        for y in 0..<diff.height {
            let row = y / cell
            for x in 0..<diff.width where diff.mask[y * diff.width + x] {
                counts[row * cols + x / cell] += 1
            }
        }

        // 8-connected components over cells that contain differences.
        var label = [Int](repeating: -1, count: cols * rows)
        var regions: [(rect: PixelRect, pixels: Int)] = []
        for start in 0..<(cols * rows) where counts[start] > 0 && label[start] < 0 {
            var stack = [start]
            label[start] = regions.count
            var minC = cols, minR = rows, maxC = 0, maxR = 0, pixels = 0
            while let index = stack.popLast() {
                let c = index % cols, r = index / cols
                minC = min(minC, c); maxC = max(maxC, c); minR = min(minR, r); maxR = max(maxR, r)
                pixels += counts[index]
                for dr in -1...1 {
                    for dc in -1...1 where dr != 0 || dc != 0 {
                        let nc = c + dc, nr = r + dr
                        guard nc >= 0, nc < cols, nr >= 0, nr < rows else { continue }
                        let n = nr * cols + nc
                        if counts[n] > 0 && label[n] < 0 {
                            label[n] = regions.count
                            stack.append(n)
                        }
                    }
                }
            }
            let rect = PixelRect(x: minC * cell, y: minR * cell, width: (maxC - minC + 1) * cell, height: (maxR - minR + 1) * cell)
                .clipped(width: diff.width, height: diff.height)
            regions.append((rect, pixels))
        }

        // Merge nearby boxes until nothing changes.
        var merged = regions
        var changed = true
        while changed {
            changed = false
            outer: for i in merged.indices {
                for j in merged.indices where j > i && merged[i].rect.isNear(merged[j].rect, gap: gap) {
                    merged[i] = (merged[i].rect.union(merged[j].rect), merged[i].pixels + merged[j].pixels)
                    merged.remove(at: j)
                    changed = true
                    break outer
                }
            }
        }

        return merged
            .filter { $0.pixels >= minPixels }
            .map { DiffRegion(rect: $0.rect, differentPixels: $0.pixels) }
            .sorted { ($0.differentPixels, $1.rect.y) > ($1.differentPixels, $0.rect.y) }
    }
}

public struct DiffRegion: Equatable, Codable, Sendable {
    /// In design pixels.
    public var rect: PixelRect
    public var differentPixels: Int
}
