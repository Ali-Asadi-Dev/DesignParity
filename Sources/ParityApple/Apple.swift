import Foundation
import ParityCore

/// Whether this build can read images, recognize text and drive the simulator (macOS only).
public enum PlatformSupport {
    #if canImport(ImageIO) && canImport(Vision)
    public static let isAvailable = true
    #else
    public static let isAvailable = false
    #endif
}

public enum AppleError: Error, CustomStringConvertible {
    case unreadableImage(String)
    case encodingFailed
    case commandFailed(String, Int32, String)
    case unsupportedPlatform

    public var description: String {
        switch self {
        case .unreadableImage(let path): "Could not read an image from \(path)."
        case .encodingFailed: "Could not encode the PNG."
        case .commandFailed(let command, let status, let output): "\(command) failed (\(status)): \(output)"
        case .unsupportedPlatform: "This needs macOS (ImageIO, Vision and the iOS Simulator)."
        }
    }
}

#if canImport(ImageIO) && canImport(Vision)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

public enum PNG {
    public static func read(_ url: URL) throws -> RGBAImage {
        try decode(Data(contentsOf: url), source: url.path)
    }

    public static func decode(_ data: Data, source: String = "data") throws -> RGBAImage {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw AppleError.unreadableImage(source)
        }
        return try rgba(from: image)
    }

    /// Draws any CGImage into an sRGB RGBA buffer and un-premultiplies it.
    static func rgba(from image: CGImage) throws -> RGBAImage {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw AppleError.unreadableImage("CGImage") }
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Int(pixels[i + 3])
            if a > 0 && a < 255 {
                for c in 0..<3 { pixels[i + c] = UInt8(min(255, Int(pixels[i + c]) * 255 / a)) }
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    static func cgImage(_ image: RGBAImage) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(image.pixels) as CFData),
              let cg = CGImage(
                width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { throw AppleError.encodingFailed }
        return cg
    }

    public static func encode(_ image: RGBAImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw AppleError.encodingFailed
        }
        CGImageDestinationAddImage(destination, try cgImage(image), nil)
        guard CGImageDestinationFinalize(destination) else { throw AppleError.encodingFailed }
        return output as Data
    }

    public static func write(_ image: RGBAImage, to url: URL) throws {
        try encode(image).write(to: url, options: .atomic)
    }
}

/// On-device text recognition (Vision). Works offline and needs no permissions.
public enum TextRecognizer {
    /// Set `PARITY_OCR_CPU_ONLY=1` on machines without a Neural Engine (e.g. CI virtual machines).
    static var cpuOnly: Bool { ProcessInfo.processInfo.environment["PARITY_OCR_CPU_ONLY"] == "1" }

    /// - Parameter languages: BCP-47 codes in priority order. Default: `PARITY_OCR_LANGUAGES`
    ///   (comma-separated) or English. Vision does not support every language (Persian, for one).
    public static func recognize(_ image: RGBAImage, languages: [String]? = nil) throws -> [TextBox] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let configured = ProcessInfo.processInfo.environment["PARITY_OCR_LANGUAGES"]?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        request.recognitionLanguages = languages ?? configured ?? ["en-US"]
        if cpuOnly { request.usesCPUOnly = true }
        let handler = VNImageRequestHandler(cgImage: try PNG.cgImage(image), options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox // normalized, origin bottom left
            return TextBox(
                text: candidate.string,
                rect: NormalizedRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            )
        }
    }
}

/// The iOS Simulator, through `xcrun simctl`.
public enum Simulator {
    /// A PNG screenshot of the device's screen ("booted" = the booted simulator).
    public static func screenshot(device: String = "booted") throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parity-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try run(["simctl", "io", device, "screenshot", "--type=png", url.path])
        return try Data(contentsOf: url)
    }

    /// Names of booted simulators, to explain failures.
    public static func bootedDevices() throws -> [String] {
        let output = try run(["simctl", "list", "devices", "booted", "-j"])
        struct List: Decodable { struct Device: Decodable { let name: String; let state: String }; let devices: [String: [Device]] }
        let list = try JSONDecoder().decode(List.self, from: Data(output.utf8))
        return list.devices.values.flatMap { $0 }.filter { $0.state == "Booted" }.map(\.name)
    }

    @discardableResult
    static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw AppleError.commandFailed("xcrun " + arguments.joined(separator: " "), process.terminationStatus, output)
        }
        return output
    }
}
#endif
