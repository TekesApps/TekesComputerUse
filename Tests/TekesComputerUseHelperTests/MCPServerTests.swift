import Foundation
import CoreGraphics
import ApplicationServices
import Testing

@testable import TekesComputerUseHelper

struct MCPServerTests {
  @Test
  func elementIndicesRetainSnapshotIdentityUntilRefreshed() throws {
    // Creating AX proxies performs no application read or action.
    let first = AXUIElementCreateApplication(1)
    let second = AXUIElementCreateApplication(2)
    let snapshots = MacAutomation.ElementSnapshots()
    snapshots.store([first, second], pid: 100)
    #expect(CFEqual(try #require(snapshots.element(pid: 100, index: 0)), first))
    #expect(snapshots.element(pid: 101, index: 0) == nil)
    #expect(snapshots.element(pid: 100, index: -1) == nil)
    #expect(snapshots.element(pid: 100, index: 2) == nil)
    snapshots.store([second, first], pid: 100)
    #expect(CFEqual(try #require(snapshots.element(pid: 100, index: 0)), second))
  }

  @Test
  func commonShortcutsResolveWithoutOperatingAnApp() throws {
    for shortcut in ["cmd+n", "cmd+N", "command+n", "super+n"] {
      let (code, flags) = try MacAutomation.keyCombination(shortcut)
      #expect(code == 45)
      #expect(flags == .maskCommand)
    }
    let (code, flags) = try MacAutomation.keyCombination("control+option+shift+z")
    #expect(code == 6)
    #expect(flags == [.maskControl, .maskAlternate, .maskShift])
    for letter in "abcdefghijklmnopqrstuvwxyz0123456789" {
      _ = try MacAutomation.keyCombination("cmd+\(letter)")
    }
    #expect(throws: (any Error).self) { try MacAutomation.keyCombination("typo+n") }
    #expect(throws: (any Error).self) { try MacAutomation.keyCombination("cmd+") }
  }

  @Test
  func catalogContainsCoreComputerUseTools() {
    let names = Set(MCPServer.tools.compactMap { $0["name"] as? String })
    #expect(
      names
        == Set([
          "list_apps", "get_app_state", "click", "drag", "press_key", "scroll", "set_value",
          "select_text", "type_text", "perform_secondary_action", "permission_status",
          "request_permissions",
        ]))
    for tool in MCPServer.tools {
      let schema = tool["inputSchema"] as? [String: Any]
      #expect(schema?["type"] as? String == "object")
      #expect(schema?["additionalProperties"] as? Bool == false)
    }
  }

  @Test
  func packageDeclaresOneGenericSignedMCPExecutableAndVersionsAgree() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let manifestData = try Data(contentsOf: root.appendingPathComponent("Plugin/tekes-plugin.json"))
    let manifest = try #require(
      JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
    let components = try #require(manifest["components"] as? [[String: Any]])
    let executablePath = "bin/TekesComputerUseHelper.app/Contents/MacOS/TekesComputerUseHelper"
    let executableComponents = components.filter { $0["path"] as? String == executablePath }
    let component = try #require(executableComponents.only)
    #expect(component["id"] as? String == "computer-use")
    #expect(component["type"] as? String == "mcp-server")
    #expect(
      Set(component["capabilities"] as? [String] ?? []) == [
        "native-helper.execute", "accessibility.control", "screen.capture",
      ])
    let declaredCapabilities = try #require(manifest["capabilities"] as? [[String: Any]])
    #expect(
      Set(declaredCapabilities.compactMap { $0["id"] as? String }) == [
        "native-helper.execute", "accessibility.control", "screen.capture",
      ])

    let infoData = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
    let info = try #require(
      PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any])
    let packageVersion = try #require(manifest["version"] as? String)
    #expect(packageVersion == "0.1.8")
    #expect(info["CFBundleShortVersionString"] as? String == packageVersion)
    #expect(MCPServer.version == packageVersion)
  }

  @Test
  func resolvesApplicationDisplayNameFromBundleIdentifier() {
    #expect(MacAutomation.applicationDisplayName(bundleIdentifier: "com.apple.iCal") != nil)
  }

  @Test
  func initializeAndToolCatalogUseMCPResultShape() async {
    let initialize = await MCPServer.handle([
      "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:],
    ])
    let initializeResult = initialize["result"] as? [String: Any]
    #expect(initializeResult?["protocolVersion"] as? String == MCPServer.legacyProtocolVersion)
    let serverInfo = initializeResult?["serverInfo"] as? [String: Any]
    let icons = serverInfo?["icons"] as? [[String: Any]]
    #expect((icons?.first?["src"] as? String)?.hasPrefix("data:image/png;base64,") == true)

    let catalog = await MCPServer.handle([
      "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:],
    ])
    let result = catalog["result"] as? [String: Any]
    #expect(result?["tools"] is [[String: Any]])
  }

  @Test
  func modernDiscoveryCatalogAndCallsRemainAvailableAlongsideLegacyMCP() async {
    let discovery = await MCPServer.handle([
      "jsonrpc": "2.0", "id": 1, "method": "server/discover",
      "params": [
        "_meta": [
          "io.modelcontextprotocol/protocolVersion": MCPServer.modernProtocolVersion
        ]
      ],
    ])
    let discoveryResult = discovery["result"] as? [String: Any]
    #expect(discoveryResult?["resultType"] as? String == "complete")
    #expect(
      discoveryResult?["supportedVersions"] as? [String] == [MCPServer.modernProtocolVersion])

    let catalog = await MCPServer.handle([
      "jsonrpc": "2.0", "id": 2, "method": "tools/list",
      "params": [
        "_meta": [
          "io.modelcontextprotocol/protocolVersion": MCPServer.modernProtocolVersion
        ]
      ],
    ])
    let catalogResult = catalog["result"] as? [String: Any]
    #expect(catalogResult?["resultType"] as? String == "complete")
    #expect(catalogResult?["ttlMs"] as? Int == 1_000)
    #expect(catalogResult?["cacheScope"] as? String == "private")

    let unknown = await MCPServer.handle([
      "jsonrpc": "2.0", "id": 3, "method": "unknown", "params": [:],
    ])
    let error = unknown["error"] as? [String: Any]
    #expect(error?["code"] as? Int == -32_601)
  }

  @Test
  func toolCallsRejectUnknownMissingAndWrongTypeArgumentsBeforeExecution() async {
    let unknown = await MCPServer.handle([
      "jsonrpc": "2.0", "id": 1, "method": "tools/call",
      "params": ["name": "list_apps", "arguments": ["unexpected": true]],
    ])
    #expect(rpcErrorMessage(unknown)?.contains("undeclared arguments") == true)

    let missing = await MCPServer.handle([
      "jsonrpc": "2.0", "id": 2, "method": "tools/call",
      "params": ["name": "click", "arguments": [:]],
    ])
    #expect(rpcErrorMessage(missing)?.contains("missing arguments: app") == true)

    let wrongType = await MCPServer.handle([
      "jsonrpc": "2.0", "id": 3, "method": "tools/call",
      "params": ["name": "click", "arguments": ["app": 42]],
    ])
    #expect(rpcErrorMessage(wrongType)?.contains("invalid argument type: app") == true)
  }

  @Test
  func launchServicesSocketArgumentRequiresANonemptyPath() {
    #expect(
      NativeHelperTransport.socketPath(in: ["helper", "--tekes-mcp-socket", "/tmp/a.sock"])
        == "/tmp/a.sock")
    #expect(NativeHelperTransport.socketPath(in: ["helper", "--tekes-mcp-socket"]) == nil)
    #expect(NativeHelperTransport.socketPath(in: ["helper", "--tekes-mcp-socket", ""]) == nil)
  }

  @Test
  func textSelectionRequiresDisambiguationAndUsesUTF16Offsets() throws {
    #expect(throws: ToolError.self) {
      try TextSelectionResolver.range(in: "alpha beta alpha", matching: "alpha")
    }

    let range = try TextSelectionResolver.range(
      in: "😀 alpha beta alpha", matching: "alpha", prefix: "beta ")
    #expect(range == NSRange(location: 14, length: 5))
  }
}

private func rpcErrorMessage(_ response: [String: Any]) -> String? {
  (response["error"] as? [String: Any])?["message"] as? String
}

extension Collection {
  fileprivate var only: Element? {
    count == 1 ? first : nil
  }
}
