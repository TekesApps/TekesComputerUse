import Foundation
import Network
import TekesComputerUsePermissionUI

/// Stateless Streamable HTTP: independent clients share one native automation process.
/// All mutable transport state is confined to `queue`; tool execution has its own FIFO.
public final class SharedHTTPServer: @unchecked Sendable {
  public struct Configuration: Codable, Sendable {
    let port: UInt16
    let bearer: String
    let ownerBearer: String
    let readyPath: String
    let leaseSeconds: Double
    let ownerPID: Int32?
    public init(port: UInt16, bearer: String, ownerBearer: String, readyPath: String, leaseSeconds: Double, ownerPID: Int32? = nil) {
      self.port = port
      self.bearer = bearer
      self.ownerBearer = ownerBearer
      self.readyPath = readyPath
      self.leaseSeconds = leaseSeconds
      self.ownerPID = ownerPID
    }
  }
  struct Ready: Codable {
    let port: UInt16
    let pid: Int32
  }
  struct Request {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
  }
  enum HTTPError: Error { case malformed, tooLarge }
  static let maxBody = 1_048_576
  private let configuration: Configuration
  private let queue = DispatchQueue(label: "com.tekes.computer-use.http")
  private let executor = SharedMCPExecutor()
  private var stopped = false
  private var listener: NWListener?
  private var peers: [ObjectIdentifier: Peer] = [:]
  private var timer: DispatchSourceTimer?
  private var heartbeat = Date()
  private var completion: CheckedContinuation<Void, any Error>?

  public init(configuration: Configuration) { self.configuration = configuration }

  public func run() async throws {
    guard configuration.bearer.count >= 32, configuration.ownerBearer.count >= 32,
      configuration.bearer != configuration.ownerBearer,
      (5...120).contains(configuration.leaseSeconds)
    else { throw HTTPError.malformed }
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        guard !self.stopped else { continuation.resume(); return }
        self.completion = continuation
        do {
          let parameters = NWParameters.tcp
          parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: self.configuration.port)!)
          let listener = try NWListener(using: parameters)
          self.listener = listener
          listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
          listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
              do {
                let ready = Ready(port: listener.port!.rawValue, pid: ProcessInfo.processInfo.processIdentifier)
                let url = URL(fileURLWithPath: self.configuration.readyPath)
                try JSONEncoder().encode(ready).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                self.heartbeat = Date()
              } catch { self.finish(error) }
            case .failed(let error): self.finish(error)
            default: break
            }
          }
          let timer = DispatchSource.makeTimerSource(queue: self.queue)
          timer.schedule(deadline: .now() + 1, repeating: 1)
          timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.heartbeat) > self.configuration.leaseSeconds { self.finish(nil) }
          }
          self.timer = timer
          timer.resume()
          listener.start(queue: self.queue)
        } catch { self.finish(error) }
      }
    }
  }

  public func stop() {
    queue.async { self.stopped = true; self.finish(nil) }
  }

  private func finish(_ error: (any Error)?) {
    guard let completion else { return }
    self.completion = nil
    timer?.cancel()
    listener?.cancel()
    for peer in peers.values { peer.connection.cancel() }
    peers.removeAll()
    Task {
      await executor.stop()
      if let error { completion.resume(throwing: error) } else { completion.resume() }
    }
  }

  private func accept(_ connection: NWConnection) {
    guard peers.count < 32 else { connection.cancel(); return }
    let peer = Peer(connection: connection, server: self)
    peers[ObjectIdentifier(connection)] = peer
    peer.start()
  }

  /// Strict, bounded HTTP/1.1 framing. Chunked uploads are deliberately rejected.
  static func parse(_ data: Data) throws -> Request? {
    guard let delimiter = data.range(of: Data("\r\n\r\n".utf8)) else {
      if data.count > 16_384 { throw HTTPError.tooLarge }
      return nil
    }
    guard delimiter.lowerBound <= 16_384,
      let text = String(data: data[..<delimiter.lowerBound], encoding: .utf8)
    else { throw HTTPError.malformed }
    let lines = text.components(separatedBy: "\r\n")
    let first = lines[0].split(separator: " ")
    guard first.count == 3, first[2] == "HTTP/1.1" else { throw HTTPError.malformed }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { throw HTTPError.malformed }
      let name = String(line[..<colon]).lowercased()
      guard !name.isEmpty, name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
        headers[name] == nil else { throw HTTPError.malformed }
      headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    guard headers["transfer-encoding"] == nil else { throw HTTPError.malformed }
    let lengthText = headers["content-length"] ?? "0"
    guard !lengthText.isEmpty, lengthText.allSatisfy({ $0.isASCII && $0.isNumber }),
      let length = Int(lengthText), length <= maxBody else { throw HTTPError.tooLarge }
    let available = data.count - delimiter.upperBound
    if available < length { return nil }
    guard available == length else { throw HTTPError.malformed }
    return Request(method: String(first[0]), path: String(first[1]), headers: headers,
      body: Data(data[delimiter.upperBound...]))
  }

  private func handle(_ request: Request, peer: Peer) {
    let authority = "127.0.0.1:\(listener!.port!.rawValue)"
    guard request.headers["host"] == authority,
      request.headers["origin"].map({ $0 == "http://\(authority)" }) ?? true
    else { peer.reply(403); return }
    let owner = request.path.hasPrefix("/owner/")
    let bearer = owner ? configuration.ownerBearer : configuration.bearer
    guard request.headers["authorization"] == "Bearer \(bearer)" else { peer.reply(401); return }
    if owner {
      guard request.method == "POST" else { peer.reply(405); return }
      switch request.path {
      case "/owner/keepalive":
        heartbeat = Date()
        peer.reply(200, body: Data("{}".utf8))
      case "/owner/permissions/accessibility", "/owner/permissions/screen-capture":
        let accessibility = request.path.hasSuffix("/accessibility")
        Task { @MainActor in
          ComputerUseAuthorization.request(accessibility: accessibility, screenCapture: !accessibility)
        }
        peer.reply(200, body: Data("{}".utf8))
      case "/owner/shutdown":
        peer.reply(200, body: Data("{}".utf8))
        queue.asyncAfter(deadline: .now() + 0.1) { self.finish(nil) }
      default: peer.reply(404)
      }
      return
    }
    guard request.path == "/mcp" else { peer.reply(404); return }
    // SSE listening and session deletion are optional for a stateless server.
    guard request.method == "POST" else { peer.reply(405); return }
    guard request.headers["content-type"]?.lowercased().split(separator: ";").first == "application/json"
    else { peer.reply(415); return }
    if let version = request.headers["mcp-protocol-version"],
      !["2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"].contains(version) {
      peer.reply(400); return
    }
    guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
      json["jsonrpc"] as? String == "2.0", json["method"] is String
    else { peer.reply(400); return }
    if json["id"] == nil { peer.reply(202); return }
    let body = request.body
    Task {
      let response = await executor.execute(body)
      queue.async { peer.reply(200, body: response) }
    }
  }

  private final class Peer: @unchecked Sendable {
    let connection: NWConnection
    let server: SharedHTTPServer
    var bytes = Data()
    var timeout: DispatchWorkItem?
    var replied = false
    init(connection: NWConnection, server: SharedHTTPServer) {
      self.connection = connection; self.server = server
    }
    func start() {
      connection.start(queue: server.queue)
      let timeout = DispatchWorkItem { [weak self] in self?.reply(408) }
      self.timeout = timeout
      server.queue.asyncAfter(deadline: .now() + 15, execute: timeout)
      receive()
    }
    func receive() {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, error in
        guard !replied else { return }
        if let data { bytes.append(data) }
        do {
          if let request = try SharedHTTPServer.parse(bytes) {
            timeout?.cancel()
            server.handle(request, peer: self)
          } else if complete || error != nil { reply(400) }
          else { receive() }
        } catch SharedHTTPServer.HTTPError.tooLarge { reply(413) }
        catch { reply(400) }
      }
    }
    func reply(_ code: Int, body: Data = Data()) {
      guard !replied else { return }
      replied = true
      timeout?.cancel()
      let extraHeaders = code == 405 ? "Allow: POST\r\n" : (code == 401 ? "WWW-Authenticate: Bearer realm=\"Tekes Computer Use\"\r\n" : "")
      var response = Data("HTTP/1.1 \(code) Response\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\(extraHeaders)\r\n".utf8)
      response.append(body)
      connection.send(content: response, completion: .contentProcessed { [self] _ in
        connection.cancel()
        server.peers.removeValue(forKey: ObjectIdentifier(connection))
      })
    }
  }
}

/// Actor isolation alone is reentrant across awaits; chaining tasks serializes whole tool calls.
actor SharedMCPExecutor {
  private var tail: Task<Data, Never>?
  private var generation = 0
  private var stopped = false
  private var tasks: [Int: Task<Data, Never>] = [:]
  private let handler: @Sendable (Data) async -> Data
  init(handler: @escaping @Sendable (Data) async -> Data = SharedMCPExecutor.handle) {
    self.handler = handler
  }
  private static func handle(_ data: Data) async -> Data {
    guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Data() }
    let response = await MCPServer.handle(request)
    return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
  }
  func stop() async {
    stopped = true
    let pending = Array(tasks.values)
    pending.forEach { $0.cancel() }
    for task in pending { _ = await task.value }
  }

  func execute(_ data: Data) async -> Data {
    guard !stopped else { return Data() }
    // Control-plane reads must remain available while a tool awaits OS consent.
    // Actual automation and permission requests still share the operation FIFO.
    if let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let method = request["method"] as? String,
      ["initialize", "server/discover", "tools/list"].contains(method)
        || (method == "tools/call"
          && (request["params"] as? [String: Any])?["name"] as? String == "permission_status") {
      return await handler(data)
    }
    let previous = tail
    generation += 1
    let current = generation
    let handler = self.handler
    let task = Task {
      _ = await previous?.value
      guard !Task.isCancelled else { return Data() }
      return await handler(data)
    }
    tail = task
    tasks[current] = task
    let response = await task.value
    tasks.removeValue(forKey: current)
    if current == generation { tail = nil }
    return response
  }
}
