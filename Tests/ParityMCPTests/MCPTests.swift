import Foundation
import Testing
@testable import ParityMCP

private let server = MCPServer(
    name: "parity",
    version: "0.1.0",
    instructions: "Check screens against designs.",
    tools: [
        MCPTool(name: "echo", description: "Echoes text", inputSchema: ["type": "object", "properties": ["text": ["type": "string"]]]) { args in
            guard let text = args["text"]?.string else { return .error("text is required") }
            return MCPToolResult(content: [.text(text), .image(data: "iVBO", mimeType: "image/png")])
        },
    ]
)

private func response(_ line: String) async throws -> JSONValue {
    let out = try #require(await server.handle(line))
    #expect(!out.contains("\n"), "responses must be single lines")
    return try JSONDecoder().decode(JSONValue.self, from: Data(out.utf8))
}

@Suite struct MCPServerTests {
    @Test func initializeNegotiatesTheProtocolVersion() async throws {
        let r = try await response(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        #expect(r["id"] == 1)
        #expect(r["result"]?["protocolVersion"] == "2025-03-26")
        #expect(r["result"]?["serverInfo"]?["name"] == "parity")
        #expect(r["result"]?["capabilities"]?["tools"] != nil)
        #expect(r["result"]?["instructions"] == "Check screens against designs.")

        let unknown = try await response(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        #expect(unknown["result"]?["protocolVersion"]?.string == MCPServer.supportedVersions[0])
    }

    @Test func notificationsGetNoResponse() async {
        #expect(await server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test func listsTools() async throws {
        let r = try await response(#"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#)
        #expect(r["id"] == "a") // string ids are echoed back as strings
        guard case .array(let tools)? = r["result"]?["tools"] else { Issue.record("no tools"); return }
        #expect(tools.count == 1)
        #expect(tools[0]["name"] == "echo")
        #expect(tools[0]["inputSchema"]?["type"] == "object")
    }

    @Test func callsToolsAndReturnsTextAndImages() async throws {
        let r = try await response(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi/there"}}}"#)
        #expect(r["result"]?["isError"] == false)
        guard case .array(let content)? = r["result"]?["content"] else { Issue.record("no content"); return }
        #expect(content[0]["type"] == "text" && content[0]["text"] == "hi/there")
        #expect(content[1]["type"] == "image" && content[1]["mimeType"] == "image/png")
    }

    @Test func toolFailuresAreResultsNotProtocolErrors() async throws {
        let r = try await response(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#)
        #expect(r["result"]?["isError"] == true)
        #expect(r["error"] == nil)
    }

    @Test func protocolErrors() async throws {
        #expect(try await response(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope"}}"#)["error"]?["code"] == -32602)
        #expect(try await response(#"{"jsonrpc":"2.0","id":6,"method":"resources/list"}"#)["error"]?["code"] == -32601)
        #expect(try await response("not json")["error"]?["code"] == -32700)
        #expect(try await response(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#)["result"] == [:])
    }

    @Test func jsonValueRoundTrips() throws {
        let value: JSONValue = ["a": [1, true, "x", .null], "b": ["c": .number(1.5)]]
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
        #expect(String(decoding: try JSONEncoder().encode(JSONValue.number(3)), as: UTF8.self) == "3")
    }
}
