import Foundation

/// Any JSON value. Used for tool arguments, schemas and JSON-RPC ids.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v):
            if v.rounded() == v && abs(v) < 1e15 { try c.encode(Int64(v)) } else { try c.encode(v) }
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
    public var double: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

public enum MCPContent: Equatable, Sendable {
    case text(String)
    /// Base64-encoded image data.
    case image(data: String, mimeType: String)

    var json: JSONValue {
        switch self {
        case .text(let text): ["type": "text", "text": .string(text)]
        case .image(let data, let mimeType): ["type": "image", "data": .string(data), "mimeType": .string(mimeType)]
        }
    }
}

public struct MCPToolResult: Equatable, Sendable {
    public var content: [MCPContent]
    public var isError: Bool

    public init(content: [MCPContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func error(_ message: String) -> MCPToolResult { MCPToolResult(content: [.text(message)], isError: true) }
}

public struct MCPTool: Sendable {
    public var name: String
    public var description: String
    /// JSON Schema for the arguments.
    public var inputSchema: JSONValue
    public var handler: @Sendable (_ arguments: JSONValue) async -> MCPToolResult

    public init(name: String, description: String, inputSchema: JSONValue,
                handler: @escaping @Sendable (_ arguments: JSONValue) async -> MCPToolResult) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.handler = handler
    }
}

/// A Model Context Protocol server over stdio: newline-delimited JSON-RPC 2.0.
/// Implements the parts tools need: `initialize`, `ping`, `tools/list`, `tools/call`.
public struct MCPServer: Sendable {
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public let name: String
    public let version: String
    public let instructions: String?
    public let tools: [MCPTool]

    public init(name: String, version: String, instructions: String? = nil, tools: [MCPTool]) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools
    }

    /// Handles one message; returns the response line, or `nil` for notifications.
    public func handle(_ line: String) async -> String? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object = message else {
            return encode(["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let method = message["method"]?.string else {
            // A response to something we never sent, or garbage: ignore unless it has an id.
            if let id = message["id"] { return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32600, "message": "Invalid request"]]) }
            return nil
        }
        guard let id = message["id"], id != .null else { return nil } // notification
        let params = message["params"] ?? [:]

        let result: JSONValue
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.string ?? Self.supportedVersions[0]
            var info: [String: JSONValue] = [
                "protocolVersion": .string(Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(name), "version": .string(version)],
            ]
            if let instructions { info["instructions"] = .string(instructions) }
            result = .object(info)
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": .array(tools.map { ["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.inputSchema] })]
        case "tools/call":
            guard let toolName = params["name"]?.string, let tool = tools.first(where: { $0.name == toolName }) else {
                return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": .string("Unknown tool: \(params["name"]?.string ?? "")")]])
            }
            let output = await tool.handler(params["arguments"] ?? [:])
            result = ["content": .array(output.content.map(\.json)), "isError": .bool(output.isError)]
        default:
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": .string("Method not found: \(method)")]])
        }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    /// Serves until stdin closes. Logs go to stderr; stdout carries only protocol messages.
    public func run() async {
        while let line = readLine(strippingNewline: true) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if let response = await handle(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }

    private func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(value)) ?? Data("{}".utf8), as: UTF8.self)
    }
}
