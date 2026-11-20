import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ParityCore
import Testing
@testable import ParityFigma

private let nodesJSON = """
{
  "name": "Tamdid",
  "nodes": {
    "12:34": {
      "document": {
        "id": "12:34", "name": "Home", "type": "FRAME",
        "absoluteBoundingBox": { "x": 1000, "y": 2000, "width": 393, "height": 852 },
        "children": [
          { "id": "1", "name": "Title", "type": "TEXT", "characters": "Tamdid",
            "absoluteBoundingBox": { "x": 1016, "y": 2100, "width": 120, "height": 41 }, "style": { "fontSize": 34 } },
          { "id": "2", "name": "Card", "type": "FRAME",
            "absoluteBoundingBox": { "x": 1016, "y": 2160, "width": 361, "height": 140 },
            "children": [
              { "id": "3", "name": "Label", "type": "TEXT", "characters": "Per month",
                "absoluteBoundingBox": { "x": 1036, "y": 2180, "width": 80, "height": 20 }, "style": { "fontSize": 15 } },
              { "id": "4", "name": "Hidden", "type": "TEXT", "characters": "Debug", "visible": false,
                "absoluteBoundingBox": { "x": 1036, "y": 2280, "width": 80, "height": 20 } },
              { "id": "5", "name": "Empty", "type": "TEXT", "characters": "  ",
                "absoluteBoundingBox": { "x": 1036, "y": 2290, "width": 80, "height": 20 } }
            ] }
        ]
      }
    }
  }
}
"""

@Suite struct FigmaTests {
    @Test func parsesFrameLinks() {
        #expect(FigmaFrameReference(url: "https://www.figma.com/design/AbC123/Tamdid?node-id=12-34&t=x")
                == FigmaFrameReference(fileKey: "AbC123", nodeID: "12:34"))
        #expect(FigmaFrameReference(url: "https://www.figma.com/file/AbC123/Tamdid?node-id=12%3A34")
                == FigmaFrameReference(fileKey: "AbC123", nodeID: "12:34"))
        #expect(FigmaFrameReference(url: "https://www.figma.com/design/AbC123/branch/Br4nch/Tamdid?node-id=1-2")?.fileKey == "Br4nch")
        #expect(FigmaFrameReference(url: "https://www.figma.com/design/AbC123/Tamdid") == nil) // no node
        #expect(FigmaFrameReference(url: "https://example.com/design/AbC123/x?node-id=1-2") == nil)
    }

    @Test func extractsVisibleTextNormalizedToTheFrame() throws {
        let frame = try FigmaClient.parseFrame(Data(nodesJSON.utf8), nodeID: "12:34")
        #expect(frame.name == "Home")
        #expect(frame.width == 393 && frame.height == 852)
        #expect(frame.texts.map(\.text) == ["Tamdid", "Per month"])
        let title = frame.texts[0]
        #expect(abs(title.rect.x - 16.0 / 393) < 1e-9)
        #expect(abs(title.rect.y - 100.0 / 852) < 1e-9)
        #expect(title.fontSize == 34)
    }

    @Test func missingNodeAndBadJSONAreReported() {
        #expect(throws: FigmaError.notFound("9:9")) { try FigmaClient.parseFrame(Data(nodesJSON.utf8), nodeID: "9:9") }
        #expect(throws: FigmaError.self) { try FigmaClient.parseFrame(Data("{}".utf8), nodeID: "12:34") }
    }

    @Test func requiresAToken() {
        #expect(throws: FigmaError.missingToken) { try FigmaClient(token: nil) }
        #expect(throws: FigmaError.missingToken) { try FigmaClient(token: "") }
    }

    @Test func downloadsThePNGThroughTheImagesEndpoint() async throws {
        final class Log: @unchecked Sendable { var requests: [URLRequest] = [] }
        let log = Log()
        let client = try FigmaClient(token: "secret") { request in
            log.requests.append(request)
            let url = request.url!.absoluteString
            if url.contains("/v1/images/") {
                return (Data(#"{"images": {"12:34": "https://cdn.example/frame.png"}}"#.utf8), 200)
            }
            return (Data([0x89, 0x50, 0x4E, 0x47]), 200)
        }
        let png = try await client.png(FigmaFrameReference(fileKey: "AbC123", nodeID: "12:34"), scale: 3)
        #expect(png == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(log.requests[0].url?.absoluteString == "https://api.figma.com/v1/images/AbC123?ids=12:34&format=png&scale=3")
        #expect(log.requests[0].value(forHTTPHeaderField: "X-Figma-Token") == "secret")
        #expect(log.requests[1].value(forHTTPHeaderField: "X-Figma-Token") == nil) // token never sent to the CDN
    }

    @Test func surfacesApiErrors() async throws {
        let client = try FigmaClient(token: "bad") { _ in (Data(#"{"status":403,"err":"Invalid token"}"#.utf8), 403) }
        await #expect(throws: FigmaError.self) { try await client.frame(FigmaFrameReference(fileKey: "x", nodeID: "1:2")) }
    }
}
