import AppKit
import ApplicationServices
import Darwin
import Foundation
import ScreenCaptureKit

@main
enum ComputerUseMain {
  @MainActor
  static func main() {
    if let index = CommandLine.arguments.firstIndex(of: "--mcp-http-config"),
      CommandLine.arguments.indices.contains(index + 1) {
      runHTTP(configurationPath: CommandLine.arguments[index + 1])
      return
    }
    Task {
      await runLegacy()
      Darwin.exit(EXIT_SUCCESS)
    }
    dispatchMain()
  }

  @MainActor
  private static func runHTTP(configurationPath: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    do {
      let data = try Data(contentsOf: URL(fileURLWithPath: configurationPath))
      let configuration = try JSONDecoder().decode(SharedHTTPServer.Configuration.self, from: data)
      // LaunchServices is the OS parent, so observe the actual Tekes owner explicitly.
      // This queue still runs if AppKit or an automation call is blocked.
      let ownerMonitor: DispatchSourceProcess?
      if let ownerPID = configuration.ownerPID, ownerPID > 1 {
        let monitor = DispatchSource.makeProcessSource(identifier: ownerPID, eventMask: .exit,
          queue: DispatchQueue(label: "com.tekes.computer-use.owner-exit"))
        monitor.setEventHandler { Darwin.exit(EXIT_SUCCESS) }
        monitor.resume()
        guard kill(ownerPID, 0) == 0 || errno != ESRCH else { return }
        ownerMonitor = monitor
      } else {
        ownerMonitor = nil
      }
      let server = SharedHTTPServer(configuration: configuration)
      Task {
        let marker = ComputerUseActivityJournal.beginSession()
        defer { ComputerUseActivityJournal.endSession(marker) }
        do {
          try await server.run()
          app.terminate(nil)
        } catch {
          FileHandle.standardError.write(Data("Computer Use HTTP service failed: \(error)\n".utf8))
          Darwin.exit(EXIT_FAILURE)
        }
      }
      // Dispatching Swift tasks is not an AppKit event loop. A visible panel needs NSApplication
      // to dequeue and dispatch NSEvents, including clicks and native dragging sessions.
      withExtendedLifetime(ownerMonitor) { app.run() }
    } catch {
      FileHandle.standardError.write(Data("Computer Use HTTP configuration failed: \(error)\n".utf8))
      Darwin.exit(EXIT_FAILURE)
    }
  }

  @MainActor
  private static func runLegacy() async {
    if let socketPath = NativeHelperTransport.socketPath(in: CommandLine.arguments) {
      NSApplication.shared.setActivationPolicy(.accessory)
      do {
        try NativeHelperTransport.acceptConnection(at: socketPath)
        await runMCPStdio()
      } catch {
        FileHandle.standardError.write(Data("native helper socket failed: \(error)\n".utf8))
        Darwin.exit(EXIT_FAILURE)
      }
      return
    }
    if shouldRunStatusBar {
      ComputerUseStatusBarApp.run()
      return
    }
    if Bundle.main.bundleURL.pathExtension == "app" {
      do {
        try await NativeHelperTransport.proxyThroughLaunchServices(
          bundleURL: Bundle.main.bundleURL)
      } catch {
        FileHandle.standardError.write(Data("native helper launch failed: \(error)\n".utf8))
        Darwin.exit(EXIT_FAILURE)
      }
      return
    }
    NSApplication.shared.setActivationPolicy(.accessory)
    await runMCPStdio()
  }

  private static func runMCPStdio() async {
    let sessionMarker = ComputerUseActivityJournal.beginSession()
    defer { ComputerUseActivityJournal.endSession(sessionMarker) }
    while let line = readLine() {
      guard let data = line.data(using: .utf8),
        let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }
      if request["method"] as? String == "notifications/initialized" { continue }
      let response = await MCPServer.handle(request)
      guard JSONSerialization.isValidJSONObject(response),
        let encoded = try? JSONSerialization.data(withJSONObject: response),
        let text = String(data: encoded, encoding: .utf8)
      else { continue }
      print(text)
      fflush(stdout)
    }
  }

  private static var shouldRunStatusBar: Bool {
    if CommandLine.arguments.contains("--mcp-stdio") { return false }
    if CommandLine.arguments.contains("--status") { return true }
    guard Bundle.main.bundleURL.pathExtension == "app",
      let bundleID = Bundle.main.bundleIdentifier,
      let serviceName = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]
    else { return false }
    return serviceName.hasPrefix("application.\(bundleID)")
  }
}
enum MCPServer {
  static let version = "0.1.8"
  static let legacyProtocolVersion = "2025-11-25"
  static let modernProtocolVersion = "2026-07-28"

  static func handle(_ request: [String: Any]) async -> [String: Any] {
    let id = request["id"] ?? NSNull()
    guard let method = request["method"] as? String else {
      return rpcError(id: id, code: -32_600, message: "invalid request")
    }
    guard ["server/discover", "initialize", "tools/list", "tools/call"].contains(method) else {
      return rpcError(id: id, code: -32_601, message: "method not found")
    }
    let modern = method == "server/discover" || isModern(request)
    do {
      let result: Any =
        switch method {
        case "server/discover":
          [
            "resultType": "complete",
            "supportedVersions": [modernProtocolVersion],
            "capabilities": ["tools": [:]],
            "_meta": ["io.modelcontextprotocol/serverInfo": serverInfo],
          ]
        case "initialize":
          [
            "protocolVersion": legacyProtocolVersion,
            "capabilities": ["tools": [:]],
            "serverInfo": serverInfo,
          ]
        case "tools/list": modernResult(["tools": tools], when: modern, cacheable: true)
        case "tools/call":
          modernResult(
            try await call(request["params"] as? [String: Any] ?? [:]), when: modern)
        default: preconditionFailure("validated MCP method was not handled")
        }
      if method == "tools/call",
        let params = request["params"] as? [String: Any],
        let name = params["name"] as? String
      {
        let arguments = params["arguments"] as? [String: Any]
        ComputerUseActivityJournal.append(
          action: activityTitle(for: name), detail: arguments?["app"] as? String)
      }
      return ["jsonrpc": "2.0", "id": id, "result": result]
    } catch {
      if method == "tools/call",
        let params = request["params"] as? [String: Any],
        let name = params["name"] as? String
      {
        let arguments = params["arguments"] as? [String: Any]
        ComputerUseActivityJournal.append(
          action: activityTitle(for: name),
          detail: arguments?["app"] as? String,
          outcome: "failed")
      }
      return rpcError(id: id, code: -32_000, message: String(describing: error))
    }
  }

  private static func activityTitle(for tool: String) -> String {
    switch tool {
    case "list_apps": "Listed applications"
    case "permission_status": "Checked permissions"
    case "request_permissions": "Requested permissions"
    case "get_app_state": "Read application state"
    case "click": "Clicked"
    case "drag": "Dragged"
    case "press_key": "Pressed key"
    case "scroll": "Scrolled"
    case "set_value": "Set value"
    case "select_text": "Selected text"
    case "type_text": "Typed text"
    case "perform_secondary_action": "Performed secondary action"
    default: "Called \(tool)"
    }
  }

  private static func isModern(_ request: [String: Any]) -> Bool {
    guard let params = request["params"] as? [String: Any],
      let metadata = params["_meta"] as? [String: Any]
    else { return false }
    return metadata["io.modelcontextprotocol/protocolVersion"] as? String
      == modernProtocolVersion
  }

  private static func modernResult(
    _ result: [String: Any],
    when modern: Bool,
    cacheable: Bool = false
  ) -> [String: Any] {
    guard modern else { return result }
    var modernResult = result
    modernResult["resultType"] = "complete"
    if cacheable {
      modernResult["ttlMs"] = 1_000
      modernResult["cacheScope"] = "private"
    }
    return modernResult
  }

  private static func rpcError(id: Any, code: Int, message: String) -> [String: Any] {
    [
      "jsonrpc": "2.0", "id": id,
      "error": ["code": code, "message": message],
    ]
  }

  static var serverInfo: [String: Any] {
    var info: [String: Any] = [
      "name": "tekes-computer-use",
      "title": "Computer Use",
      "version": version,
    ]
    let installedIcon = Bundle.main.resourceURL?.appendingPathComponent("ComputerUseIcon.png")
    let sourceIcon =
      URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Plugin/assets/ComputerUseIcon.png")
    if let iconURL = [installedIcon, sourceIcon].compactMap({ $0 }).first(where: {
      FileManager.default.isReadableFile(atPath: $0.path)
    }), let data = try? Data(contentsOf: iconURL), data.count <= 512 * 1_024 {
      info["icons"] = [
        [
          "src": "data:image/png;base64,\(data.base64EncodedString())",
          "mimeType": "image/png",
          "sizes": ["128x128"],
        ]
      ]
    }
    return info
  }

  static var tools: [[String: Any]] {
    [
      tool("list_apps", "List running macOS applications.", [:], readOnly: true),
      tool(
        "permission_status", "Read Accessibility and Screen Recording permission state.", [:],
        readOnly: true),
      tool(
        "request_permissions", "Ask macOS to show Accessibility and Screen Recording consent UI.",
        ["accessibility": ["type": "boolean"], "screen_capture": ["type": "boolean"]],
        destructive: true,
        approval: [
          "kind": "macos_permission",
          "title": "Allow Computer Use on this Mac",
          "detail": "macOS will show the final system consent UI after you continue.",
          "permissions": [
            ["argument": "accessibility", "label": "Accessibility", "requestedByDefault": true],
            [
              "argument": "screen_capture", "label": "Screen Recording", "requestedByDefault": true,
            ],
          ],
        ]),
      tool(
        "get_app_state", "Read one app accessibility tree and capture its front window.",
        ["app": ["type": "string"], "disableDiff": ["type": "boolean"]], readOnly: true,
        required: ["app"]),
      tool(
        "click", "Click an accessibility element or screen coordinate.",
        [
          "app": ["type": "string"], "element_index": ["type": "integer"],
          "x": ["type": "number"], "y": ["type": "number"],
          "mouse_button": ["type": "string"], "click_count": ["type": "integer"],
        ],
        required: ["app"]),
      tool(
        "drag", "Drag between screen coordinates.",
        [
          "app": ["type": "string"], "from_x": ["type": "number"],
          "from_y": ["type": "number"], "to_x": ["type": "number"],
          "to_y": ["type": "number"],
        ], required: ["app", "from_x", "from_y", "to_x", "to_y"]),
      tool(
        "press_key", "Press a key or modifier combination in an app.",
        ["app": ["type": "string"], "key": ["type": "string"]], required: ["app", "key"]),
      tool(
        "scroll", "Scroll an app vertically or horizontally.",
        [
          "app": ["type": "string"], "element_index": ["type": "integer"],
          "direction": ["type": "string"], "pages": ["type": "number"],
        ],
        required: ["app", "direction"]),
      tool(
        "set_value", "Set an accessibility element value.",
        [
          "app": ["type": "string"], "element_index": ["type": "integer"],
          "value": ["type": "string"],
        ], required: ["app", "element_index", "value"]),
      tool(
        "select_text", "Select text or place the cursor in an accessibility text element.",
        [
          "app": ["type": "string"], "element_index": ["type": "integer"],
          "text": ["type": "string"], "selection_type": ["type": "string"],
          "prefix": ["type": "string"], "suffix": ["type": "string"],
        ],
        required: ["app", "element_index", "text"]),
      tool(
        "type_text", "Type Unicode text into the focused app.",
        ["app": ["type": "string"], "text": ["type": "string"]], required: ["app", "text"]),
      tool(
        "perform_secondary_action", "Perform an AX action explicitly exposed by an element.",
        [
          "app": ["type": "string"], "element_index": ["type": "integer"],
          "action": ["type": "string"],
        ], required: ["app", "element_index", "action"]),
    ]
  }

  private static func tool(
    _ name: String, _ description: String, _ properties: [String: Any],
    readOnly: Bool = false, destructive: Bool = false, required: [String] = [],
    approval: [String: Any]? = nil
  ) -> [String: Any] {
    var descriptor: [String: Any] = [
      "name": name, "description": description,
      "inputSchema": [
        "type": "object", "properties": properties, "required": required,
        "additionalProperties": false,
      ],
      "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive],
    ]
    if let approval { descriptor["_meta"] = ["com.tekes/approval": approval] }
    return descriptor
  }

  private static func call(_ params: [String: Any]) async throws -> [String: Any] {
    let name = params["name"] as? String ?? ""
    guard params["arguments"] == nil || params["arguments"] is [String: Any] else {
      throw ToolError("tool arguments must be an object")
    }
    let a = params["arguments"] as? [String: Any] ?? [:]
    try validate(a, forTool: name)
    let text: String
    var image: String?
    switch name {
    case "list_apps": text = try JSON.text(MacAutomation.listApps())
    case "permission_status": text = try JSON.text(MacAutomation.permissionStatus())
    case "request_permissions":
      let state = await MacAutomation.requestPermissions(
        accessibility: a["accessibility"] as? Bool == true,
        screenCapture: a["screen_capture"] as? Bool == true)
      text = try JSON.text(state.jsonObject)
    case "get_app_state":
      let state = try await MacAutomation.appState(app: string(a, "app"))
      text = state.text
      image = state.pngBase64
    case "click":
      try await MacAutomation.click(a)
      text = "clicked"
    case "drag":
      try await MacAutomation.drag(a)
      text = "dragged"
    case "press_key":
      try MacAutomation.pressKey(a)
      text = "pressed"
    case "scroll":
      try MacAutomation.scroll(a)
      text = "scrolled"
    case "set_value":
      try MacAutomation.setValue(a)
      text = "value set"
    case "select_text":
      try MacAutomation.selectText(a)
      text = "text selected"
    case "type_text":
      try MacAutomation.typeText(a)
      text = "typed"
    case "perform_secondary_action":
      try MacAutomation.secondaryAction(a)
      text = "action performed"
    default: throw ToolError("unknown tool: \(name)")
    }
    var content: [[String: Any]] = [["type": "text", "text": text]]
    if let image { content.append(["type": "image", "mimeType": "image/png", "data": image]) }
    var result: [String: Any] = ["content": content, "isError": false]
    if let bundleIdentifier = a["app"] as? String, !bundleIdentifier.isEmpty {
      var presentation: [String: Any] = [
        "icon": ["kind": "application", "bundleIdentifier": bundleIdentifier]
      ]
      if let displayName = MacAutomation.applicationDisplayName(
        bundleIdentifier: bundleIdentifier)
      {
        presentation["target"] = ["kind": "application", "displayName": displayName]
      }
      result["_meta"] = [
        "com.tekes/presentation": presentation
      ]
    }
    return result
  }

  private static func validate(_ arguments: [String: Any], forTool name: String) throws {
    guard let descriptor = tools.first(where: { $0["name"] as? String == name }),
      let schema = descriptor["inputSchema"] as? [String: Any],
      schema["additionalProperties"] as? Bool == false,
      let properties = schema["properties"] as? [String: [String: Any]],
      let required = schema["required"] as? [String]
    else { throw ToolError("unknown tool: \(name)") }
    let unknown = Set(arguments.keys).subtracting(properties.keys).sorted()
    guard unknown.isEmpty else {
      throw ToolError("undeclared arguments: \(unknown.joined(separator: ","))")
    }
    let missing = required.filter { arguments[$0] == nil }.sorted()
    guard missing.isEmpty else {
      throw ToolError("missing arguments: \(missing.joined(separator: ","))")
    }
    for (key, value) in arguments {
      let expected = properties[key]?["type"] as? String
      guard matchesSchemaType(value, expected: expected) else {
        throw ToolError("invalid argument type: \(key)")
      }
    }
  }

  private static func matchesSchemaType(_ value: Any, expected: String?) -> Bool {
    switch expected {
    case "string": return value is String
    case "boolean":
      guard let number = value as? NSNumber else { return false }
      return CFGetTypeID(number) == CFBooleanGetTypeID()
    case "integer":
      guard let number = value as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID()
      else { return false }
      let scalar = number.doubleValue
      return scalar.isFinite && scalar.rounded(.towardZero) == scalar
    case "number":
      guard let number = value as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID()
      else { return false }
      return number.doubleValue.isFinite
    default: return false
    }
  }

  private static func string(_ values: [String: Any], _ key: String) throws -> String {
    guard let value = values[key] as? String, !value.isEmpty else {
      throw ToolError("missing \(key)")
    }
    return value
  }
}

struct ToolError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

enum JSON {
  static func text(_ object: Any) throws -> String {
    String(
      data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      encoding: .utf8)!
  }
}
