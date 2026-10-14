import Foundation
import Testing
@testable import TekesComputerUseHelper

struct SharedHTTPServerTests {
  @Test func stoppingTheServiceCancelsQueuedAutomation() async throws {
    actor Probe {
      var calls = 0
      func handle(_ data: Data) async -> Data {
        calls += 1
        do { try await Task.sleep(for: .seconds(20)) } catch { }
        return data
      }
    }
    let probe = Probe()
    let executor = SharedMCPExecutor { await probe.handle($0) }
    let first = Task { await executor.execute(Data("first".utf8)) }
    while await probe.calls == 0 { await Task.yield() }
    let second = Task { await executor.execute(Data("second".utf8)) }
    await executor.stop()
    _ = await first.value
    _ = await second.value
    #expect(await probe.calls == 1)
    #expect(await executor.execute(Data("after-stop".utf8)).isEmpty)
  }

  @Test func httpTransportStartsAndStopsWithoutTerminatingItsOwner() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let readyURL = root.appendingPathComponent("ready.json")
    let bearer = String(repeating: "a", count: 40)
    let server = SharedHTTPServer(configuration: .init(port: 0, bearer: bearer,
      ownerBearer: String(repeating: "b", count: 40), readyPath: readyURL.path, leaseSeconds: 30))
    let task = Task { try await server.run() }
    defer { server.stop() }
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: readyURL.path) {
      try await Task.sleep(for: .milliseconds(20))
    }
    let ready = try JSONDecoder().decode(SharedHTTPServer.Ready.self, from: Data(contentsOf: readyURL))
    #expect(ready.pid == ProcessInfo.processInfo.processIdentifier)
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(ready.port)/mcp")!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
    let (data, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self).contains("permission_status"))
    request.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
    let (_, rejected) = try await URLSession.shared.data(for: request)
    #expect((rejected as? HTTPURLResponse)?.statusCode == 401)
    // Harness credentials cannot open system permission UI through the owner route.
    request.url = URL(string: "http://127.0.0.1:\(ready.port)/owner/permissions/accessibility")!
    request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    let (_, ownerRejected) = try await URLSession.shared.data(for: request)
    #expect((ownerRejected as? HTTPURLResponse)?.statusCode == 401)
    server.stop()
    try await task.value
    #expect(ProcessInfo.processInfo.processIdentifier == ready.pid)
  }

  @Test func statusReadsBypassAnAwaitingOperation() async throws {
    actor Probe {
      var started = false
      var finished = false
      func handle(_ data: Data) async -> Data {
        if data == Data("operation".utf8) {
          started = true
          try? await Task.sleep(for: .milliseconds(200))
          finished = true
          return data
        }
        return Data((finished ? "blocked" : "responsive").utf8)
      }
    }
    let probe = Probe()
    let executor = SharedMCPExecutor { await probe.handle($0) }
    let operation = Task { await executor.execute(Data("operation".utf8)) }
    while !(await probe.started) { await Task.yield() }
    for request: [String: Any] in [
      ["method": "tools/list"],
      ["method": "tools/call", "params": ["name": "permission_status"]],
    ] {
      let data = try JSONSerialization.data(withJSONObject: request)
      #expect(await executor.execute(data) == Data("responsive".utf8))
    }
    _ = await operation.value
  }

  @Test func fragmentedRequestsWaitForTheCompleteBody() throws {
    let header = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:1\r\nContent-Length: 2\r\n\r\n"
    #expect(try SharedHTTPServer.parse(Data((header + "{").utf8)) == nil)
    let parsed = try SharedHTTPServer.parse(Data((header + "{}").utf8))
    let request = try #require(parsed)
    #expect(request.path == "/mcp")
    #expect(request.body == Data("{}".utf8))
  }

  @Test func ambiguousOrUnboundedFramingIsRejected() {
    for headers in ["Content-Length: 0\r\ncontent-length: 1", "Transfer-Encoding: chunked",
      "Content-Length: -1", "Content-Length: 9999999999"] {
      #expect(throws: (any Error).self) {
        try SharedHTTPServer.parse(Data("POST /mcp HTTP/1.1\r\n\(headers)\r\n\r\n".utf8))
      }
    }
    #expect(throws: (any Error).self) { try SharedHTTPServer.parse(Data(repeating: 65, count: 16_385)) }
  }

  @Test func suspendingToolCallsDoNotOverlapAcrossClients() async {
    actor Probe {
      var active = false
      func handle(_ data: Data) async -> Data {
        if active { return Data("overlap".utf8) }
        active = true
        try? await Task.sleep(for: .milliseconds(20))
        active = false
        return data
      }
    }
    let probe = Probe()
    let executor = SharedMCPExecutor { await probe.handle($0) }
    await withTaskGroup(of: Data.self) { group in
      for _ in 0..<6 { group.addTask { await executor.execute(Data("ok".utf8)) } }
      for await result in group { #expect(result == Data("ok".utf8)) }
    }
  }
}
