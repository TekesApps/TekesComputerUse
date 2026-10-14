import AppKit
import Darwin
import Foundation

/// Keeps the host-facing stdio MCP contract while moving the TCC-using process behind a
/// LaunchServices-owned application boundary. A directly spawned process is only a byte proxy;
/// the signed `.app` instance accepted by LaunchServices owns Accessibility and ScreenCaptureKit.
enum NativeHelperTransport {
  static let socketArgument = "--tekes-mcp-socket"

  enum TransportError: Error, CustomStringConvertible {
    case invalidSocketPath
    case systemCall(String, Int32)
    case launch(String)
    case connectionTimedOut

    var description: String {
      switch self {
      case .invalidSocketPath: "native helper socket path is invalid"
      case .systemCall(let operation, let code):
        "\(operation) failed: \(String(cString: strerror(code)))"
      case .launch(let reason): "LaunchServices could not start the native helper: \(reason)"
      case .connectionTimedOut: "timed out connecting to the LaunchServices native helper"
      }
    }
  }

  static func socketPath(in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: socketArgument),
      arguments.indices.contains(index + 1)
    else { return nil }
    let path = arguments[index + 1]
    return path.isEmpty ? nil : path
  }

  @MainActor
  static func proxyThroughLaunchServices(bundleURL: URL) async throws {
    let socketPath = "/tmp/tekes-cu-\(UUID().uuidString).sock"
    defer { unlink(socketPath) }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.createsNewApplicationInstance = true
    configuration.arguments = [socketArgument, socketPath]
    do {
      _ = try await NSWorkspace.shared.openApplication(
        at: bundleURL,
        configuration: configuration)
    } catch {
      throw TransportError.launch(error.localizedDescription)
    }

    let socket = try await connect(to: socketPath)
    bridgeStandardIO(to: socket)
  }

  static func acceptConnection(at path: String) throws {
    unlink(path)
    let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw systemError("socket") }
    defer {
      Darwin.close(listener)
      unlink(path)
    }

    var address = try unixAddress(path: path)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { throw systemError("bind") }
    guard Darwin.listen(listener, 1) == 0 else { throw systemError("listen") }

    let connection = Darwin.accept(listener, nil, nil)
    guard connection >= 0 else { throw systemError("accept") }
    defer { Darwin.close(connection) }
    guard dup2(connection, STDIN_FILENO) >= 0 else { throw systemError("dup2(stdin)") }
    guard dup2(connection, STDOUT_FILENO) >= 0 else { throw systemError("dup2(stdout)") }
  }

  private static func connect(to path: String) async throws -> Int32 {
    try await Task.detached(priority: .userInitiated) {
      for attempt in 0..<100 {
        let connection = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard connection >= 0 else { throw systemError("socket") }
        var address = try unixAddress(path: path)
        let result = withUnsafePointer(to: &address) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(connection, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
          }
        }
        if result == 0 { return connection }
        let code = errno
        Darwin.close(connection)
        if ![ENOENT, ECONNREFUSED].contains(code) { throw systemError("connect", code: code) }
        if attempt < 99 { usleep(50_000) }
      }
      throw TransportError.connectionTimedOut
    }.value
  }

  private static func bridgeStandardIO(to socket: Int32) {
    let inputFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      copyBytes(from: STDIN_FILENO, to: socket)
      Darwin.shutdown(socket, SHUT_WR)
      inputFinished.signal()
    }
    copyBytes(from: socket, to: STDOUT_FILENO)
    inputFinished.wait()
    Darwin.close(socket)
  }

  private static func copyBytes(from source: Int32, to destination: Int32) {
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      let count = Darwin.read(source, &buffer, buffer.count)
      guard count > 0 else { return }
      var offset = 0
      while offset < count {
        let written = buffer.withUnsafeBytes {
          Darwin.write(destination, $0.baseAddress!.advanced(by: offset), count - offset)
        }
        guard written > 0 else { return }
        offset += written
      }
    }
  }

  private static func unixAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
      throw TransportError.invalidSocketPath
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    path.withCString { source in
      withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
        _ = strlcpy(destination, source, pathCapacity)
      }
    }
    return address
  }

  private static func systemError(_ operation: String, code: Int32 = errno) -> TransportError {
    .systemCall(operation, code)
  }
}
