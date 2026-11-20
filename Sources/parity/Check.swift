import Foundation
import ParityApple
import ParityCore
import ParityFigma

/// Inputs shared by the CLI and the MCP tools.
struct CheckInput: Sendable {
    /// A Figma frame link, or a path to a design PNG.
    var design: String
    /// A path to a screenshot PNG, or "simulator" / a simulator UDID to capture one now.
    var actual: String = "simulator"
    var options = Comparison.Options()
    /// Screen width in points; `nil` uses the Figma frame width, or 393 (iPhone 15/16/17) for PNGs.
    var widthPoints: Double?
    var compareText = true
    var outputDirectory: URL?
}

struct CheckOutput: Sendable {
    var report: Report
    var overlay: RGBAImage
    var files: [String]
}

enum Check {
    static let defaultWidthPoints = 393.0

    static func run(_ input: CheckInput) async throws -> CheckOutput {
        #if canImport(ImageIO) && canImport(Vision)
        var options = input.options

        // Design: Figma frame (image + text layers) or a PNG (text by OCR).
        let designImage: RGBAImage
        var designText: [TextBox]?
        if let ref = FigmaFrameReference(url: input.design) {
            let client = try FigmaClient(token: ProcessInfo.processInfo.environment["FIGMA_TOKEN"])
            async let frameInfo = client.frame(ref)
            async let png = client.png(ref, scale: 3)
            let (frame, data) = try await (frameInfo, png)
            designImage = try PNG.decode(data, source: input.design)
            designText = frame.texts
            options.screenWidthPoints = input.widthPoints ?? frame.width
        } else {
            designImage = try PNG.read(URL(fileURLWithPath: input.design))
            options.screenWidthPoints = input.widthPoints ?? defaultWidthPoints
            if input.compareText { designText = try TextRecognizer.recognize(designImage) }
        }

        // Actual: a screenshot file, or the simulator right now.
        let actualImage: RGBAImage
        if FileManager.default.fileExists(atPath: input.actual) {
            actualImage = try PNG.read(URL(fileURLWithPath: input.actual))
        } else {
            let device = input.actual == "simulator" ? "booted" : input.actual
            actualImage = try PNG.decode(try Simulator.screenshot(device: device), source: "simulator \(device)")
        }
        let actualText = input.compareText ? try TextRecognizer.recognize(actualImage) : nil

        let report = Comparison.run(design: designImage, actual: actualImage, designText: input.compareText ? designText : nil,
                                    actualText: actualText, options: options)
        let overlay = Overlay.render(actual: actualImage, report: report)

        var files: [String] = []
        if let directory = input.outputDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let items: [(String, Data)] = [
                ("report.md", Data(report.markdown().utf8)),
                ("report.json", Data(report.json().utf8)),
                ("overlay.png", try PNG.encode(overlay)),
                ("design.png", try PNG.encode(designImage)),
                ("actual.png", try PNG.encode(actualImage)),
            ]
            for (name, data) in items {
                let url = directory.appendingPathComponent(name)
                try data.write(to: url, options: .atomic)
                files.append(url.path)
            }
        }
        return CheckOutput(report: report, overlay: overlay, files: files)
        #else
        throw AppleError.unsupportedPlatform
        #endif
    }

    /// A small PNG of the overlay for agents: 1 pixel per point keeps tokens low.
    static func previewPNG(_ output: CheckOutput) throws -> Data {
        #if canImport(ImageIO) && canImport(Vision)
        let width = Int(output.report.comparedSize.width) / max(Int(output.report.scale.rounded()), 1)
        let height = output.overlay.height * width / max(output.overlay.width, 1)
        return try PNG.encode(output.overlay.resized(width: max(width, 1), height: max(height, 1)))
        #else
        throw AppleError.unsupportedPlatform
        #endif
    }
}
