import AppKit
import ApplicationServices
import Foundation
import ScreenCaptureKit
import TekesComputerUsePermissionUI

enum MacAutomation {
  // Preserve the identity shown in get_app_state. Re-enumeration can move menu items and
  // silently turn an old "New Event" index into an unrelated action such as Quit.
  final class ElementSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [pid_t: [AXUIElement]] = [:]

    func store(_ elements: [AXUIElement], pid: pid_t) {
      lock.lock()
      defer { lock.unlock() }
      if snapshots.count >= 32 { snapshots.removeAll() }
      snapshots[pid] = elements
    }

    func element(pid: pid_t, index: Int) -> AXUIElement? {
      lock.lock()
      defer { lock.unlock() }
      guard let elements = snapshots[pid], elements.indices.contains(index) else { return nil }
      return elements[index]
    }
  }
  private static let elementSnapshots = ElementSnapshots()

  struct PermissionState: Sendable {
    let accessibility: Bool
    let screenCapture: Bool

    var jsonObject: [String: Any] {
      ["accessibility": accessibility, "screen_capture": screenCapture]
    }
  }

  struct State {
    let text: String
    let pngBase64: String?
  }

  static func permissionStatus() -> [String: Any] {
    currentPermissionState().jsonObject
  }

  @MainActor
  static func requestPermissions(
    accessibility: Bool,
    screenCapture: Bool
  ) async -> PermissionState {
    _ = requestPermissionsDirect(accessibility: accessibility, screenCapture: screenCapture)
    for _ in 0..<1_200 {
      let state = currentPermissionState()
      if (!accessibility || state.accessibility) && (!screenCapture || state.screenCapture) {
        return state
      }
      do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
    }
    return currentPermissionState()
  }

  @MainActor
  static func requestPermissionsDirect(accessibility: Bool, screenCapture: Bool) -> PermissionState {
    ComputerUseAuthorization.request(accessibility: accessibility, screenCapture: screenCapture)
    return currentPermissionState()
  }

  static func currentPermissionState() -> PermissionState {
    PermissionState(
      accessibility: AXIsProcessTrusted(),
      screenCapture: CGPreflightScreenCaptureAccess())
  }

  static func listApps() -> [[String: Any]] {
    NSWorkspace.shared.runningApplications.compactMap { app in
      guard app.activationPolicy == .regular else { return nil }
      return [
        "id": app.bundleIdentifier ?? app.bundleURL?.path ?? String(app.processIdentifier),
        "displayName": app.localizedName ?? "",
        "isRunning": !app.isTerminated,
      ]
    }.sorted { ($0["displayName"] as? String ?? "") < ($1["displayName"] as? String ?? "") }
  }

  static func applicationDisplayName(bundleIdentifier: String) -> String? {
    if let running = NSWorkspace.shared.runningApplications.first(where: {
      $0.bundleIdentifier == bundleIdentifier
    }), let name = running.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
      !name.isEmpty
    {
      return name
    }
    guard
      let url = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: bundleIdentifier)
    else { return nil }
    if let bundle = Bundle(url: url) {
      for key in ["CFBundleDisplayName", "CFBundleName"] {
        if let name = bundle.localizedInfoDictionary?[key] as? String
          ?? bundle.infoDictionary?[key] as? String,
          !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          return name
        }
      }
    }
    return url.deletingPathExtension().lastPathComponent
  }

  static func appState(app identifier: String) async throws -> State {
    let app = try resolve(identifier)
    guard AXIsProcessTrusted() else { throw ToolError("accessibility permission is not granted") }
    let elements = elements(for: app)
    elementSnapshots.store(elements, pid: app.processIdentifier)
    let lines = elements.enumerated().map { index, element in describe(element, index: index) }
    var screenshot: Data?
    var screenshotDiagnostic = ""
    if CGPreflightScreenCaptureAccess() {
      do {
        screenshot = try await screenshotPNG(for: app)
        if screenshot == nil {
          screenshotDiagnostic = "\nscreenshot=unavailable(no on-screen window)"
        }
      } catch {
        screenshotDiagnostic = "\nscreenshot=unavailable(\(error.localizedDescription))"
      }
    } else {
      screenshotDiagnostic = "\nscreenshot=unavailable(screen capture permission is not granted)"
    }
    return State(
      text: "app=\(app.bundleIdentifier ?? identifier) pid=\(app.processIdentifier)\n"
        + lines.joined(separator: "\n") + screenshotDiagnostic,
      pngBase64: screenshot?.base64EncodedString())
  }

  static func click(_ a: [String: Any]) async throws {
    let app = try resolve(required(a, "app"))
    app.activate()
    if let index = a["element_index"] as? Int {
      let element = try indexedElement(app, index)
      if let point = center(element) { await ComputerUsePointer.shared.flash(at: point) }
      if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return }
      if let point = center(element) {
        postClick(point, button: a["mouse_button"] as? String, count: a["click_count"] as? Int ?? 1)
        return
      }
      throw ToolError("element cannot be clicked")
    }
    guard let x = number(a["x"]), let y = number(a["y"]) else {
      throw ToolError("click needs element_index or x/y")
    }
    await ComputerUsePointer.shared.flash(at: CGPoint(x: x, y: y))
    postClick(
      CGPoint(x: x, y: y), button: a["mouse_button"] as? String,
      count: a["click_count"] as? Int ?? 1)
  }

  static func drag(_ a: [String: Any]) async throws {
    _ = try resolve(required(a, "app"))
    let from = CGPoint(x: try requiredNumber(a, "from_x"), y: try requiredNumber(a, "from_y"))
    let to = CGPoint(x: try requiredNumber(a, "to_x"), y: try requiredNumber(a, "to_y"))
    await ComputerUsePointer.shared.flash(at: from)
    CGEvent(
      mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from,
      mouseButton: .left)?.post(tap: .cghidEventTap)
    // Keep the visible pointer and injected drag on the same path. Always release the button,
    // including when the request is cancelled during the animation.
    for step in 1...18 {
      let fraction = Double(step) / 18
      let point = CGPoint(
        x: from.x + (to.x - from.x) * fraction,
        y: from.y + (to.y - from.y) * fraction)
      await ComputerUsePointer.shared.show(at: point)
      CGEvent(
        mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point,
        mouseButton: .left)?.post(tap: .cghidEventTap)
      try? await Task.sleep(for: .milliseconds(16))
    }
    CGEvent(
      mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)?
      .post(tap: .cghidEventTap)
  }

  static func scroll(_ a: [String: Any]) throws {
    _ = try resolve(required(a, "app"))
    let pages = max(1, Int(number(a["pages"]) ?? 1))
    let amount = Int32(pages * 600)
    let direction = try required(a, "direction").lowercased()
    let vertical: Int32 =
      ["down", "d"].contains(direction) ? -amount : (["up", "u"].contains(direction) ? amount : 0)
    let horizontal: Int32 =
      ["right", "r"].contains(direction)
      ? -amount : (["left", "l"].contains(direction) ? amount : 0)
    CGEvent(
      scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: vertical,
      wheel2: horizontal, wheel3: 0)?.post(tap: .cghidEventTap)
  }

  static func setValue(_ a: [String: Any]) throws {
    let app = try resolve(required(a, "app"))
    let index = try requiredInt(a, "element_index")
    let status = AXUIElementSetAttributeValue(
      try indexedElement(app, index), kAXValueAttribute as CFString,
      try required(a, "value") as CFTypeRef)
    guard status == .success else { throw ToolError("AX set value failed: \(status.rawValue)") }
  }

  static func selectText(_ a: [String: Any]) throws {
    let app = try resolve(required(a, "app"))
    let element = try indexedElement(app, try requiredInt(a, "element_index"))
    let needle = try required(a, "text")
    let fullText: String = value(element, kAXValueAttribute) ?? ""
    let prefix = a["prefix"] as? String
    let suffix = a["suffix"] as? String
    let utf16Range = try TextSelectionResolver.range(
      in: fullText, matching: needle, prefix: prefix, suffix: suffix)
    let selectionType = (a["selection_type"] as? String ?? "range").lowercased()
    var selectedRange: CFRange
    switch selectionType {
    case "cursor_before": selectedRange = CFRange(location: utf16Range.location, length: 0)
    case "cursor_after": selectedRange = CFRange(location: NSMaxRange(utf16Range), length: 0)
    case "range", "select":
      selectedRange = CFRange(location: utf16Range.location, length: utf16Range.length)
    default: throw ToolError("unsupported selection_type: \(selectionType)")
    }
    guard let axRange = AXValueCreate(.cfRange, &selectedRange) else {
      throw ToolError("could not create AX text range")
    }
    let status = AXUIElementSetAttributeValue(
      element, kAXSelectedTextRangeAttribute as CFString, axRange)
    guard status == .success else {
      throw ToolError("AX text selection failed: \(status.rawValue)")
    }
  }

  static func secondaryAction(_ a: [String: Any]) throws {
    let app = try resolve(required(a, "app"))
    let element = try indexedElement(app, try requiredInt(a, "element_index"))
    let action = try required(a, "action") as CFString
    guard AXUIElementPerformAction(element, action) == .success else {
      throw ToolError("AX action is unavailable")
    }
  }

  static func typeText(_ a: [String: Any]) throws {
    let app = try resolve(required(a, "app"))
    app.activate()
    let text = try required(a, "text")
    var units = Array(text.utf16)
    let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
    down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
    down?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)?.post(tap: .cghidEventTap)
  }

  static func pressKey(_ a: [String: Any]) throws {
    let (code, flags) = try keyCombination(required(a, "key"))
    let app = try resolve(required(a, "app"))
    app.activate()
    for down in [true, false] {
      let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
      event?.flags = flags
      event?.post(tap: .cghidEventTap)
    }
  }

  /// Physical ANSI keys for shortcuts; arbitrary Unicode text belongs to type_text.
  static func keyCombination(_ value: String) throws -> (CGKeyCode, CGEventFlags) {
    let parts = value.lowercased().split(separator: "+", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    let key = parts.last ?? ""
    let map: [String: CGKeyCode] = [
      "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
      "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
      "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
      "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
      "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
      "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
      "n": 45, "m": 46, ".": 47, "`": 50,
      "return": 36, "enter": 36, "tab": 48, "escape": 53, "esc": 53,
      "up": 126, "down": 125, "left": 123, "right": 124, "space": 49,
      "backspace": 51, "delete": 117, "home": 115, "end": 119,
      "pageup": 116, "pagedown": 121,
      "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
      "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
    guard let code = map[key] else { throw ToolError("unsupported key: \(key)") }
    var flags: CGEventFlags = []
    for modifier in parts.dropLast() {
      switch modifier {
      case "super", "cmd", "command": flags.insert(.maskCommand)
      case "shift": flags.insert(.maskShift)
      case "alt", "option": flags.insert(.maskAlternate)
      case "ctrl", "control": flags.insert(.maskControl)
      default: throw ToolError("unsupported modifier: \(modifier)")
      }
    }
    return (code, flags)
  }

  private static func resolve(_ identifier: String) throws -> NSRunningApplication {
    let apps = NSWorkspace.shared.runningApplications
    if let app = apps.first(where: {
      $0.bundleIdentifier == identifier
        || $0.localizedName?.caseInsensitiveCompare(identifier) == .orderedSame
        || $0.bundleURL?.path == identifier
    }) {
      return app
    }
    throw ToolError("app not found: \(identifier)")
  }

  private static func elements(for app: NSRunningApplication) -> [AXUIElement] {
    var result: [AXUIElement] = []
    var queue = [AXUIElementCreateApplication(app.processIdentifier)]
    while !queue.isEmpty && result.count < 400 {
      let element = queue.removeFirst()
      result.append(element)
      if let children: [AXUIElement] = value(element, kAXChildrenAttribute) {
        queue.append(contentsOf: children)
      }
    }
    return result
  }

  private static func indexedElement(_ app: NSRunningApplication, _ index: Int) throws
    -> AXUIElement
  {
    guard let element = elementSnapshots.element(pid: app.processIdentifier, index: index),
      let _: String = value(element, kAXRoleAttribute)
    else { throw ToolError("stale or invalid element_index; call get_app_state again") }
    return element
  }

  private static func describe(_ e: AXUIElement, index: Int) -> String {
    let role: String = value(e, kAXRoleAttribute) ?? "AXUnknown"
    let title: String = value(e, kAXTitleAttribute) ?? ""
    let val: String = value(e, kAXValueAttribute) ?? ""
    var actions: CFArray?
    AXUIElementCopyActionNames(e, &actions)
    return
      "[\(index)] role=\(role) title=\(String(title.prefix(160))) value=\(String(val.prefix(160))) actions=\((actions as? [String] ?? []).joined(separator: ","))"
  }

  private static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else {
      return nil
    }
    return raw as? T
  }
  private static func center(_ e: AXUIElement) -> CGPoint? {
    guard let position: AXValue = value(e, kAXPositionAttribute),
      let size: AXValue = value(e, kAXSizeAttribute)
    else { return nil }
    var p = CGPoint.zero
    var s = CGSize.zero
    AXValueGetValue(position, .cgPoint, &p)
    AXValueGetValue(size, .cgSize, &s)
    return CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
  }
  private static func postClick(_ p: CGPoint, button: String?, count: Int) {
    let b: CGMouseButton = ["right", "r"].contains(button ?? "") ? .right : .left
    let down: CGEventType = b == .right ? .rightMouseDown : .leftMouseDown
    let up: CGEventType = b == .right ? .rightMouseUp : .leftMouseUp
    for i in 1...max(1, count) {
      let d = CGEvent(
        mouseEventSource: nil, mouseType: down, mouseCursorPosition: p, mouseButton: b)
      d?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
      d?.post(tap: .cghidEventTap)
      CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: p, mouseButton: b)?.post(
        tap: .cghidEventTap)
    }
  }

  private static func screenshotPNG(for app: NSRunningApplication) async throws -> Data? {
    let content = try await SCShareableContent.excludingDesktopWindows(
      true, onScreenWindowsOnly: true)
    guard
      let window = content.windows.filter({
        $0.owningApplication?.processID == app.processIdentifier && $0.frame.width > 1
          && $0.frame.height > 1
      }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    else { return nil }
    let configuration = SCStreamConfiguration()
    let maximumDimension = 2_048.0
    let scale = min(2.0, maximumDimension / max(window.frame.width, window.frame.height))
    configuration.width = max(1, Int(window.frame.width * scale))
    configuration.height = max(1, Int(window.frame.height * scale))
    // The pointer is not part of application state, and large-pointer capture is unreliable on
    // current macOS Tahoe builds.
    configuration.showsCursor = false
    configuration.capturesAudio = false
    configuration.excludesCurrentProcessAudio = true
    let image = try await SCScreenshotManager.captureImage(
      contentFilter: SCContentFilter(desktopIndependentWindow: window),
      configuration: configuration)
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
  }

  private static func required(_ a: [String: Any], _ key: String) throws -> String {
    guard let s = a[key] as? String, !s.isEmpty else { throw ToolError("missing \(key)") }
    return s
  }
  private static func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
  private static func requiredNumber(_ a: [String: Any], _ key: String) throws -> Double {
    guard let n = number(a[key]) else { throw ToolError("missing \(key)") }
    return n
  }
  private static func requiredInt(_ a: [String: Any], _ key: String) throws -> Int {
    guard let n = a[key] as? Int else { throw ToolError("missing \(key)") }
    return n
  }
}
