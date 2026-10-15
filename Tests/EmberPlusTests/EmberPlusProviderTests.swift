//
// Copyright (c) 2026 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an 'AS IS' BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

@testable import EmberPlus
import Synchronization
import XCTest

/// A consumer at the other end of an in-memory transport.
final class TestConsumer: Sendable {
  private let toProvider: AsyncStream<[UInt8]>.Continuation
  private let fromProviderStream: AsyncStream<[UInt8]>
  let transport: Transport

  struct Transport: EmberPlusTransport {
    let inbound: AsyncStream<[UInt8]>
    let outbound: AsyncStream<[UInt8]>.Continuation
    let peerDescription = "test"

    func read() async throws -> [UInt8] {
      var iterator = inbound.makeAsyncIterator()
      return await iterator.next() ?? []
    }

    func write(_ bytes: [UInt8]) async throws {
      outbound.yield(bytes)
    }

    func close() {
      outbound.finish()
    }
  }

  init() {
    let (inbound, toProvider) = AsyncStream.makeStream(of: [UInt8].self)
    let (fromProvider, outbound) = AsyncStream.makeStream(of: [UInt8].self)
    self.toProvider = toProvider
    fromProviderStream = fromProvider
    transport = Transport(inbound: inbound, outbound: outbound)
  }

  func send(_ root: GlowRoot) {
    for packet in S101Message.packets(for: root.encoded()) {
      toProvider.yield(S101.frame(packet.encoded))
    }
  }

  func sendRaw(_ bytes: [UInt8]) {
    toProvider.yield(bytes)
  }

  func disconnect() {
    toProvider.finish()
  }

  enum Event: Equatable {
    case keepAliveResponse
    case glow(GlowRoot)
  }

  /// What the provider sends, deframed and reassembled.
  func events() -> AsyncStream<Event> {
    let stream = fromProviderStream
    return AsyncStream { continuation in
      let task = Task {
        var deframer = S101.Deframer()
        var reassembler = S101Message.Reassembler()
        for await bytes in stream {
          for case let .message(bytes, _) in deframer.receive(bytes) {
            switch try? S101Message(decoding: bytes).command {
            case .keepAliveResponse?:
              continuation.yield(.keepAliveResponse)
            case let .ember(packet)?:
              if case let .message(payload)? = reassembler.receive(packet),
                 let root = try? GlowRoot(decoding: payload)
              {
                continuation.yield(.glow(root))
              }
            default:
              break
            }
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

/// A device node with a gain and a name.
final class TestTreeSource: EmberPlusTreeSource {
  let gain = Mutex(0.0)
  let sessions = Mutex([EmberPlusSession]())

  func sessionStarted(_ session: EmberPlusSession) async {
    sessions.withLock { $0.append(session) }
  }

  func sessionEnded(_ session: EmberPlusSession) async {
    sessions.withLock { $0.removeAll { $0 == session } }
  }

  var gainParameter: GlowElement {
    .parameter(GlowParameter(.path([1, 1]), contents: GlowParameterContents(
      identifier: "gain",
      value: .real(gain.withLock { $0 }),
      access: .readWrite
    )))
  }

  func getDirectory(
    _ path: GlowPath,
    fieldMask: GlowFieldFlags,
    session: EmberPlusSession
  ) async -> [GlowElement] {
    switch path {
    case []:
      [.node(GlowNode(.path([1]), contents: GlowNodeContents(identifier: "device")))]
    case [1]:
      [gainParameter] + [.parameter(GlowParameter(.path([1, 2]), contents: GlowParameterContents(
        identifier: "name",
        value: .string(String(repeating: "x", count: 2000)),
        access: .read
      )))]
    default:
      []
    }
  }

  func setValue(
    _ value: GlowValue,
    at path: GlowPath,
    session: EmberPlusSession
  ) async -> [GlowElement] {
    guard path == [1, 1], case let .real(value) = value else { return [] }
    gain.withLock { $0 = value }
    // announce to everyone else; the requester is answered by the return value
    for other in sessions.withLock({ $0 }) where other != session {
      other.send(.elements([gainParameter]))
    }
    return [gainParameter]
  }

  func invoke(
    _ invocation: GlowInvocation,
    at path: GlowPath,
    session: EmberPlusSession
  ) async -> GlowInvocationResult? {
    let sum = (invocation.arguments ?? []).reduce(Int64(0)) {
      guard case let .integer(value) = $1 else { return $0 }
      return $0 + value
    }
    return GlowInvocationResult(
      invocationID: invocation.invocationID ?? 0,
      success: true,
      result: [.integer(sum)]
    )
  }
}

final class EmberPlusProviderTests: XCTestCase {
  func testRequestsResolveNestedPaths() {
    let root = GlowRoot.elements([
      .node(GlowNode(.number(1), children: [
        .node(GlowNode(.number(3), children: [.command(GlowCommand(.getDirectory))])),
        .parameter(GlowParameter(.number(2), contents: GlowParameterContents(value: .integer(5)))),
      ])),
      .command(GlowCommand(.getDirectory, dirFieldMask: .all)),
      .node(GlowNode(.path([4, 5]), children: [.command(GlowCommand(.subscribe))])),
      .function(GlowFunction(.path([6]), children: [
        .command(GlowCommand(.invoke, invocation: GlowInvocation(invocationID: 1))),
      ])),
    ])
    XCTAssertEqual(EmberPlusRequest.requests(in: root), [
      .getDirectory([1, 3], .default),
      .setValue([1, 2], .integer(5)),
      .getDirectory([], .all),
      .subscribe([4, 5]),
      .invoke([6], GlowInvocation(invocationID: 1)),
    ])
  }

  func testSession() async throws {
    let source = TestTreeSource()
    let provider = EmberPlusProvider(source: source)
    let consumer = TestConsumer()
    let serving = Task { await provider.serve(consumer.transport) }
    var events = consumer.events().makeAsyncIterator()

    // keep-alive, in either framing
    consumer.sendRaw(S101.frame(S101Message(command: .keepAliveRequest).encoded))
    var event = await events.next()
    XCTAssertEqual(event, .keepAliveResponse)
    consumer.sendRaw(S101.frame(
      S101Message(command: .keepAliveRequest).encoded,
      framing: .nonEscaping
    ))
    event = await events.next()
    XCTAssertEqual(event, .keepAliveResponse)

    consumer.send(.elements([.command(GlowCommand(.getDirectory))]))
    event = await events.next()
    XCTAssertEqual(
      event,
      .glow(.elements([.node(GlowNode(.path([1]), contents: GlowNodeContents(identifier: "device")))]))
    )

    // a reply over a kilobyte is split into packets, which the consumer reassembles
    consumer.send(.elements([.node(GlowNode(.path([1]), children: [
      .command(GlowCommand(.getDirectory)),
    ]))]))
    event = await events.next()
    guard case let .glow(.elements(elements))? = event else { return XCTFail() }
    XCTAssertEqual(elements.count, 2)

    consumer.send(.elements([.node(GlowNode(.number(1), children: [
      .parameter(GlowParameter(.number(1), contents: GlowParameterContents(value: .real(-6)))),
    ]))]))
    event = await events.next()
    XCTAssertEqual(event, .glow(.elements([source.gainParameter])))
    XCTAssertEqual(source.gain.withLock { $0 }, -6)

    consumer.send(.elements([.function(GlowFunction(.path([1, 3]), children: [
      .command(GlowCommand(.invoke, invocation: GlowInvocation(
        invocationID: 9,
        arguments: [.integer(2), .integer(3)]
      ))),
    ]))]))
    event = await events.next()
    XCTAssertEqual(event, .glow(.invocationResult(
      GlowInvocationResult(invocationID: 9, success: true, result: [.integer(5)])
    )))

    consumer.disconnect()
    await serving.value
    XCTAssertTrue(source.sessions.withLock { $0.isEmpty })
  }

  func testOverTCP() async throws {
    let source = TestTreeSource()
    let provider = EmberPlusProvider(source: source)
    let listener = try EmberPlusListener(port: 0, loopback: true)
    let serving = Task { try await provider.serve(listener: listener) }
    defer { serving.cancel() }

    let client = try await TestTCPClient(port: listener.port)
    defer { client.close() }
    let request = S101Message.packets(for: GlowRoot.elements([
      .command(GlowCommand(.getDirectory)),
    ]).encoded())[0]
    try await client.write(S101.frame(request.encoded))

    var deframer = S101.Deframer()
    var reassembler = S101Message.Reassembler()
    while true {
      let bytes = try await client.read()
      guard !bytes.isEmpty else { return XCTFail("the provider closed the connection") }
      for case let .message(bytes, _) in deframer.receive(bytes) {
        guard case let .ember(packet) = try S101Message(decoding: bytes).command,
              case let .message(payload)? = reassembler.receive(packet) else { continue }
        XCTAssertEqual(
          try GlowRoot(decoding: payload),
          .elements([.node(GlowNode(.path([1]), contents: GlowNodeContents(identifier: "device")))])
        )
        client.close()
        // the session ends with the connection
        for _ in 0..<500 where !source.sessions.withLock({ $0.isEmpty }) {
          try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(source.sessions.withLock { $0.isEmpty })
        return
      }
    }
  }

  /// The provider's end of a loopback connection to `client`, accepted by its own listener.
  private func accept(
    _ body: @Sendable (_ transport: any EmberPlusTransport, _ client: TestTCPClient) async throws -> ()
  ) async throws {
    let listener = try EmberPlusListener(port: 0, loopback: true)
    let (accepted, continuation) = AsyncStream.makeStream(of: (any EmberPlusTransport).self)
    let listening = Task { try await listener.run { continuation.yield($0) } }
    defer { listening.cancel() }
    let client = try await TestTCPClient(port: listener.port)
    defer { client.close() }
    var iterator = accepted.makeAsyncIterator()
    guard let transport = await iterator.next() else { return XCTFail("nothing accepted") }
    try await body(transport, client)
  }

  func testTransportReadsEmptyAtEndOfStream() async throws {
    try await accept { transport, client in
      XCTAssertFalse(transport.peerDescription.isEmpty)
      XCTAssertNotEqual(transport.peerDescription, "unknown")
      try await client.write([1, 2, 3])
      var received = [UInt8]()
      while received.count < 3 {
        let bytes = try await transport.read()
        XCTAssertFalse(bytes.isEmpty)
        received += bytes
      }
      XCTAssertEqual(received, [1, 2, 3])
      client.close()
      let bytes = try await transport.read()
      XCTAssertEqual(bytes, [])
    }
  }

  func testTransportCloseEndsPendingRead() async throws {
    try await accept { transport, client in
      let reading = Task { try await transport.read() }
      // give the read time to be in flight
      try await Task.sleep(for: .milliseconds(100))
      transport.close()
      let bytes = try await reading.value
      XCTAssertEqual(bytes, [])
      // and the consumer sees the end of the stream
      let clientBytes = try await client.read()
      XCTAssertEqual(clientBytes, [])
    }
  }

  func testTransportWriteToGoneConsumerThrows() async throws {
    try await accept { transport, client in
      client.close()
      // the first writes may go out before the peer's reset comes back
      let bytes = [UInt8](repeating: 0, count: 4096)
      for _ in 0..<100 {
        do {
          try await transport.write(bytes)
        } catch {
          return
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTFail("writes to a closed connection kept succeeding")
    }
  }
}
