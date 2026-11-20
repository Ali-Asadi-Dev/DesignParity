import Foundation
import ParityApple
import ParityCore
import ParityFigma
import ParityMCP

/// The MCP tools: what an agent needs for an implement → check → fix loop.
enum ParityTools {
    static let instructions = """
    DesignParity checks an iOS screen against its design. After implementing or changing a screen:
    1. Build and run the app in the iOS Simulator and navigate to the screen.
    2. Call check_design with the Figma frame link (or a design PNG).
    3. Fix what the report lists (positions are in points from the top left), rebuild, and check again until it passes.
    Use ignore_top_points (59 on Dynamic Island iPhones) so the status bar is not compared.
    """

    static func server() -> MCPServer {
        MCPServer(name: "design-parity", version: Parity.version, instructions: instructions, tools: [checkDesign, captureSimulator])
    }

    static let checkDesign = MCPTool(
        name: "check_design",
        description: "Compare the running iOS Simulator screen (or a screenshot) with a Figma frame or design PNG. Returns a report of differing areas and text (missing, changed, moved, resized) in points, plus an overlay image with differences in red.",
        inputSchema: [
            "type": "object",
            "properties": [
                "design": ["type": "string", "description": "Figma frame link with node-id (needs FIGMA_TOKEN), or an absolute path to a design PNG."],
                "actual": ["type": "string", "description": "Absolute path to a screenshot PNG. Default: capture the booted simulator now."],
                "ignore_top_points": ["type": "number", "description": "Points to ignore at the top (status bar). Typical: 59."],
                "ignore_bottom_points": ["type": "number", "description": "Points to ignore at the bottom (home indicator). Typical: 34."],
                "width_points": ["type": "number", "description": "Screen width in points when the design is a PNG. Default 393."],
                "pass_threshold": ["type": "number", "description": "Minimum share of matching pixels, 0–1. Default 0.995. Any differing area also fails."],
                "output_dir": ["type": "string", "description": "Where to save report.md, report.json and overlay.png."],
            ],
            "required": ["design"],
        ]
    ) { args in
        guard let design = args["design"]?.string else { return .error("`design` is required.") }
        var input = CheckInput(design: design)
        if let actual = args["actual"]?.string { input.actual = actual }
        if let v = args["ignore_top_points"]?.double { input.options.ignoreTopPoints = v }
        if let v = args["ignore_bottom_points"]?.double { input.options.ignoreBottomPoints = v }
        if let v = args["pass_threshold"]?.double { input.options.passThreshold = v }
        input.widthPoints = args["width_points"]?.double
        input.outputDirectory = URL(fileURLWithPath: args["output_dir"]?.string ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("parity-\(Int(Date().timeIntervalSince1970))").path)
        do {
            let output = try await Check.run(input)
            var text = output.report.markdown()
            if !output.files.isEmpty { text += "\nSaved: " + output.files.joined(separator: ", ") + "\n" }
            return MCPToolResult(content: [.text(text), .image(data: try Check.previewPNG(output).base64EncodedString(), mimeType: "image/png")])
        } catch {
            return .error(explain(error))
        }
    }

    static let captureSimulator = MCPTool(
        name: "capture_simulator",
        description: "Take a screenshot of the booted iOS Simulator and return it.",
        inputSchema: [
            "type": "object",
            "properties": [
                "device": ["type": "string", "description": "Simulator UDID, or `booted` (default)."],
                "path": ["type": "string", "description": "Where to save the PNG (optional)."],
            ],
        ]
    ) { args in
        #if canImport(ImageIO) && canImport(Vision)
        do {
            let png = try Simulator.screenshot(device: args["device"]?.string ?? "booted")
            var content: [MCPContent] = []
            if let path = args["path"]?.string {
                try png.write(to: URL(fileURLWithPath: path))
                content.append(.text("Saved \(path)"))
            }
            // Return a 1x copy to keep the response small.
            let image = try PNG.decode(png)
            let small = image.resized(width: image.width / 3, height: image.height / 3)
            content.append(.image(data: try PNG.encode(small).base64EncodedString(), mimeType: "image/png"))
            return MCPToolResult(content: content)
        } catch {
            return .error(explain(error))
        }
        #else
        return .error(AppleError.unsupportedPlatform.description)
        #endif
    }

    /// Errors written so an agent knows what to do next.
    static func explain(_ error: Error) -> String {
        switch error {
        case let error as FigmaError: return error.description
        case let error as AppleError:
            if case .commandFailed = error { return "\(error)\nIs a simulator booted? Boot one with `xcrun simctl boot \"iPhone 16\"` and run the app first." }
            return error.description
        default: return "\(error)"
        }
    }
}
