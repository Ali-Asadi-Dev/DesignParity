import ArgumentParser
import Foundation
import ParityApple
import ParityCore
import ParityFigma
import ParityMCP

@main
struct Parity: AsyncParsableCommand {
    static let version = "0.1.0"

    static let configuration = CommandConfiguration(
        commandName: "parity",
        abstract: "Check that an iOS screen matches its design: pixels, layout and text.",
        discussion: """
        Compare a Figma frame (or a design PNG) with a screenshot or the running iOS Simulator.
        Run `parity mcp` to let an AI coding agent (Claude Code, Cursor, Codex…) use the same checks.
        """,
        version: version,
        subcommands: [Compare.self, Capture.self, FigmaFrame.self, MCP.self],
        defaultSubcommand: Compare.self
    )
}

struct CompareOptions: ParsableArguments {
    @Option(help: "Points to ignore at the top, e.g. 59 for the status bar on Dynamic Island iPhones.")
    var ignoreTop: Double = 0

    @Option(help: "Points to ignore at the bottom, e.g. 34 for the home indicator.")
    var ignoreBottom: Double = 0

    @Option(help: "Screen width in points. Default: the Figma frame's width, or 393 for PNGs.")
    var widthPoints: Double?

    @Option(help: "Pixel color threshold from 0 to 1; lower is stricter.")
    var threshold: Double = 0.1

    @Option(name: .customLong("pass"), help: "Minimum share of matching pixels, 0–1. Any differing area also fails.")
    var passThreshold: Double = 0.995

    @Flag(inversion: .prefixedNo, help: "Compare text with on-device text recognition.")
    var text = true

    func input(design: String, actual: String, output: String?) -> CheckInput {
        var options = Comparison.Options()
        options.threshold = threshold
        options.ignoreTopPoints = ignoreTop
        options.ignoreBottomPoints = ignoreBottom
        options.passThreshold = passThreshold
        return CheckInput(design: design, actual: actual, options: options, widthPoints: widthPoints, compareText: text,
                          outputDirectory: output.map { URL(fileURLWithPath: $0) })
    }
}

struct Compare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Compare a design with a screenshot or the running simulator.",
        discussion: "Exits with status 1 when the screen does not match, so it can gate CI."
    )

    @Argument(help: "A Figma frame link (needs FIGMA_TOKEN) or a design PNG.")
    var design: String

    @Argument(help: "A screenshot PNG, `simulator` for the booted simulator, or a simulator UDID.")
    var actual: String = "simulator"

    @OptionGroup var options: CompareOptions

    @Option(name: .shortAndLong, help: "Directory for report.md, report.json, overlay.png and the inputs.")
    var output: String = "parity-report"

    @Flag(help: "Print JSON instead of Markdown.")
    var json = false

    func run() async throws {
        let result = try await Check.run(options.input(design: design, actual: actual, output: output))
        print(json ? result.report.json() : result.report.markdown())
        if !json { print("Files: \(output)/") }
        if !result.report.passed { throw ExitCode(1) }
    }
}

struct Capture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Save a screenshot of the booted iOS Simulator.")

    @Option(help: "Simulator UDID or `booted`.")
    var device = "booted"

    @Option(name: .shortAndLong, help: "Where to save the PNG.")
    var output = "screenshot.png"

    func run() async throws {
        #if canImport(ImageIO) && canImport(Vision)
        try Simulator.screenshot(device: device).write(to: URL(fileURLWithPath: output))
        print(output)
        #else
        throw AppleError.unsupportedPlatform
        #endif
    }
}

struct FigmaFrame: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "figma",
        abstract: "Download a Figma frame as PNG plus its text layers (needs FIGMA_TOKEN)."
    )

    @Argument(help: "A Figma frame link with a node-id.")
    var url: String

    @Option(name: .shortAndLong, help: "Where to save the PNG; the text layers go next to it as .json.")
    var output = "design.png"

    @Option(help: "Export scale, 1–4.")
    var scale = 3

    func run() async throws {
        guard let ref = FigmaFrameReference(url: url) else { throw ValidationError("Not a Figma frame link with a node-id: \(url)") }
        let client = try FigmaClient(token: ProcessInfo.processInfo.environment["FIGMA_TOKEN"])
        let png = try await client.png(ref, scale: scale)
        let frame = try await client.frame(ref)
        try png.write(to: URL(fileURLWithPath: output))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let textsURL = URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("json")
        try encoder.encode(frame.texts).write(to: textsURL)
        print("\(frame.name): \(Int(frame.width))×\(Int(frame.height)) pt, \(frame.texts.count) text layers → \(output), \(textsURL.path)")
    }
}

struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run as a Model Context Protocol server on stdio for AI coding agents.",
        discussion: """
        Claude Code:  claude mcp add parity -- parity mcp
        Other clients: run `parity mcp` as a stdio server. Set FIGMA_TOKEN to compare with Figma links.
        """
    )

    func run() async throws {
        await ParityTools.server().run()
    }
}
