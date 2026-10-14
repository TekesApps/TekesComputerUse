import Darwin
import Foundation

struct ComputerUseActivity: Codable, Sendable {
  let timestamp: Date
  let host: String
  let action: String
  let detail: String?
  let outcome: String
}

enum ComputerUseActivityJournal {
  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()
  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()

  private static var rootURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/TekesComputerUse", isDirectory: true)
  }
  private static var activityURL: URL { rootURL.appendingPathComponent("activity.jsonl") }
  private static var sessionsURL: URL {
    rootURL.appendingPathComponent("sessions", isDirectory: true)
  }

  static func beginSession() -> URL? {
    let url = sessionsURL.appendingPathComponent("\(getpid()).session")
    do {
      try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
      try Data(hostName.utf8).write(to: url, options: .atomic)
      append(action: "MCP session connected", outcome: "connected")
      return url
    } catch {
      return nil
    }
  }

  static func endSession(_ marker: URL?) {
    guard let marker else { return }
    try? FileManager.default.removeItem(at: marker)
    append(action: "MCP session disconnected", outcome: "idle")
  }

  static func append(action: String, detail: String? = nil, outcome: String = "succeeded") {
    do {
      try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
      let item = ComputerUseActivity(
        timestamp: Date(), host: hostName, action: action, detail: detail, outcome: outcome)
      var data = try encoder.encode(item)
      data.append(0x0A)
      let descriptor = open(activityURL.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
      guard descriptor >= 0 else { return }
      defer { close(descriptor) }
      data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        _ = Darwin.write(descriptor, base, bytes.count)
      }
    } catch {
      // Diagnostics must never break an MCP call.
    }
  }

  static func activeSessions() -> [(host: String, pid: Int32)] {
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: sessionsURL, includingPropertiesForKeys: nil)
    else { return [] }
    return urls.compactMap { url in
      guard let pid = Int32(url.deletingPathExtension().lastPathComponent) else { return nil }
      if kill(pid, 0) != 0 && errno == ESRCH {
        try? FileManager.default.removeItem(at: url)
        return nil
      }
      let host = (try? String(contentsOf: url, encoding: .utf8)) ?? "Local MCP host"
      return (host.trimmingCharacters(in: .whitespacesAndNewlines), pid)
    }
  }

  static func recentActivities(limit: Int = 20) -> [ComputerUseActivity] {
    guard let data = try? Data(contentsOf: activityURL),
      let source = String(data: data.suffix(128 * 1_024), encoding: .utf8)
    else { return [] }
    return source.split(separator: "\n").suffix(limit).compactMap { line in
      try? decoder.decode(ComputerUseActivity.self, from: Data(line.utf8))
    }.reversed()
  }

  static var diagnosticsText: String {
    let bundle = Bundle.main
    let permissions = MacAutomation.currentPermissionState()
    return """
      Tekes Computer Use
      Version: \(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
      Bundle ID: \(bundle.bundleIdentifier ?? "unknown")
      Path: \(bundle.bundleURL.path)
      Architecture: \(architecture)
      Accessibility: \(permissions.accessibility ? "allowed" : "missing")
      Screen Recording: \(permissions.screenCapture ? "allowed" : "missing")
      Active MCP sessions: \(activeSessions().count)
      """
  }

  private static var hostName: String {
    let environment = ProcessInfo.processInfo.environment
    for key in ["TEKES_COMPUTER_USE_HOST", "MCP_HOST_NAME", "DSH_HOST_NAME"] {
      if let value = environment[key], !value.isEmpty { return value }
    }
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let length = proc_pidpath(getppid(), &buffer, UInt32(buffer.count))
    if length > 0 {
      let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
      return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).lastPathComponent
    }
    return "Local MCP host"
  }

  private static var architecture: String {
    #if arch(arm64)
      return "arm64"
    #elseif arch(x86_64)
      return "x86_64"
    #else
      return "unknown"
    #endif
  }
}
