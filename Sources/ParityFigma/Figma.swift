import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ParityCore

/// A frame in a Figma file, from a link such as
/// `https://www.figma.com/design/AbC123/Checkout?node-id=12-34`.
public struct FigmaFrameReference: Equatable, Sendable {
    public var fileKey: String
    /// API form, with a colon: "12:34".
    public var nodeID: String

    public init(fileKey: String, nodeID: String) {
        self.fileKey = fileKey
        self.nodeID = nodeID
    }

    public init?(url: String) {
        guard let components = URLComponents(string: url),
              let host = components.host, host.hasSuffix("figma.com") else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard let kind = parts.firstIndex(where: { ["file", "design", "proto", "board"].contains($0) }),
              kind + 1 < parts.count else { return nil }
        // Branch links: /design/<file>/branch/<branchKey>/<name>
        var key = parts[kind + 1]
        if kind + 3 < parts.count, parts[kind + 2] == "branch" { key = parts[kind + 3] }
        guard let node = components.queryItems?.first(where: { $0.name == "node-id" })?.value, !node.isEmpty else { return nil }
        self.init(fileKey: key, nodeID: node.replacingOccurrences(of: "-", with: ":"))
    }
}

/// The parts of a frame DesignParity needs: its size and its text layers.
public struct FigmaFrame: Equatable, Sendable {
    public var name: String
    public var width: Double
    public var height: Double
    /// Text layers, normalized to the frame, with Figma's font sizes.
    public var texts: [TextBox]
}

public enum FigmaError: Error, Equatable, CustomStringConvertible {
    case missingToken
    case http(Int, String)
    case notFound(String)
    case invalidResponse(String)

    public var description: String {
        switch self {
        case .missingToken: "Set FIGMA_TOKEN to a Figma personal access token (Figma → Settings → Security)."
        case .http(let code, let body): "Figma API error \(code): \(body)"
        case .notFound(let id): "Node \(id) was not found in the file."
        case .invalidResponse(let reason): "Unexpected Figma response: \(reason)"
        }
    }
}

/// Minimal Figma REST client: one frame's PNG and its text layers.
public struct FigmaClient: Sendable {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, Int)

    let token: String
    let fetch: Fetch

    public init(token: String?, fetch: Fetch? = nil) throws {
        guard let token, !token.isEmpty else { throw FigmaError.missingToken }
        self.token = token
        self.fetch = fetch ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// Text layers and size of the frame.
    public func frame(_ ref: FigmaFrameReference) async throws -> FigmaFrame {
        let data = try await get("https://api.figma.com/v1/files/\(ref.fileKey)/nodes?ids=\(escape(ref.nodeID))")
        return try Self.parseFrame(data, nodeID: ref.nodeID)
    }

    /// The frame rendered as PNG at `scale` (1…4).
    public func png(_ ref: FigmaFrameReference, scale: Int = 3) async throws -> Data {
        let data = try await get("https://api.figma.com/v1/images/\(ref.fileKey)?ids=\(escape(ref.nodeID))&format=png&scale=\(scale)")
        struct Images: Decodable { let images: [String: String?]?; let err: String? }
        let response = try JSONDecoder().decode(Images.self, from: data)
        if let err = response.err { throw FigmaError.invalidResponse(err) }
        guard let link = response.images?[ref.nodeID] ?? nil, let url = URL(string: link) else { throw FigmaError.notFound(ref.nodeID) }
        let (png, status) = try await fetch(URLRequest(url: url))
        guard status == 200 else { throw FigmaError.http(status, "image download") }
        return png
    }

    private func get(_ link: String) async throws -> Data {
        var request = URLRequest(url: URL(string: link)!)
        request.setValue(token, forHTTPHeaderField: "X-Figma-Token")
        let (data, status) = try await fetch(request)
        guard status == 200 else { throw FigmaError.http(status, String(decoding: data.prefix(300), as: UTF8.self)) }
        return data
    }

    private func escape(_ id: String) -> String {
        // Node ids look like "12:34" (or "I12:34;56:78" inside instances). Keep ':' readable, as Figma's docs do.
        id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+;"))) ?? id
    }

    // MARK: - Parsing

    struct Node: Decodable {
        struct Box: Decodable { let x: Double; let y: Double; let width: Double; let height: Double }
        struct Style: Decodable { let fontSize: Double? }
        let id: String?
        let name: String?
        let type: String
        let visible: Bool?
        let characters: String?
        let absoluteBoundingBox: Box?
        let style: Style?
        let children: [Node]?
    }

    static func parseFrame(_ data: Data, nodeID: String) throws -> FigmaFrame {
        struct Response: Decodable {
            struct Entry: Decodable { let document: Node }
            let nodes: [String: Entry?]
        }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw FigmaError.invalidResponse("\(error)")
        }
        guard let entry = response.nodes[nodeID] ?? nil else { throw FigmaError.notFound(nodeID) }
        let root = entry.document
        guard let frame = root.absoluteBoundingBox, frame.width > 0, frame.height > 0 else {
            throw FigmaError.invalidResponse("node \(nodeID) has no bounds")
        }
        var texts: [TextBox] = []
        func walk(_ node: Node) {
            if node.visible == false { return }
            if node.type == "TEXT", let characters = node.characters, let box = node.absoluteBoundingBox,
               !characters.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                texts.append(TextBox(
                    text: characters,
                    rect: NormalizedRect(x: (box.x - frame.x) / frame.width, y: (box.y - frame.y) / frame.height,
                                         width: box.width / frame.width, height: box.height / frame.height),
                    fontSize: node.style?.fontSize
                ))
            }
            node.children?.forEach(walk)
        }
        walk(root)
        return FigmaFrame(name: root.name ?? nodeID, width: frame.width, height: frame.height, texts: texts)
    }
}
