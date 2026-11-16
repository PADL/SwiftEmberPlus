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

import Logging
import Synchronization

/// The consumer end of an Ember+ connection, for tools and tests: it sends Glow requests,
/// answers keep-alives, and hands over what the provider sends, a message at a time.
///
/// Ember+ does not number its requests: a reply is the next message about the element
/// asked of, and anything else that arrives meanwhile (a tally, a changed parameter) waits
/// for `next`. One request at a time.
public final class EmberPlusConsumer: Sendable {
  public enum Error: Swift.Error, Sendable, Hashable {
    /// No reply came in time.
    case timedOut
    /// The provider closed the connection.
    case closed
  }

  private let transport: any EmberPlusTransport
  private let logger: Logger
  private let inbox = EmberPlusConsumerInbox()
  private let reader = Mutex<Task<(), Never>?>(nil)

  public var peerDescription: String {
    transport.peerDescription
  }

  public init(
    transport: some EmberPlusTransport,
    logger: Logger = Logger(label: "com.padl.EmberPlus.EmberPlusConsumer")
  ) {
    self.transport = transport
    self.logger = logger
    let task = Task { [transport, inbox, logger] in
      await Self.read(transport, into: inbox, logger: logger)
    }
    reader.withLock { $0 = task }
  }

  /// A consumer of the provider at `host` (a name or address) on TCP.
  public static func connect(
    host: String,
    port: UInt16 = 9000,
    logger: Logger = Logger(label: "com.padl.EmberPlus.EmberPlusConsumer")
  ) async throws -> EmberPlusConsumer {
    try await EmberPlusConsumer(
      transport: emberPlusTCPConnection(host: host, port: port),
      logger: logger
    )
  }

  deinit {
    close()
  }

  public func close() {
    transport.close()
    reader.withLock { $0?.cancel() }
  }

  public func send(_ root: GlowRoot) async throws {
    for packet in S101Message.packets(for: root.encoded()) {
      try await transport.write(S101.frame(packet.encoded))
    }
  }

  /// The next message the provider sent, or nil if none comes in time or the connection
  /// has closed.
  public func next(timeout: Duration = .seconds(5)) async -> GlowRoot? {
    await inbox.next(timeout: timeout) { _ in true }
  }

  /// The children of the element at `path` (the root when empty), or the element itself,
  /// as qualified elements. The session hears of their changes from then on.
  public func getDirectory(
    _ path: GlowPath,
    timeout: Duration = .seconds(5)
  ) async throws -> [GlowElement] {
    let command = GlowElement.command(GlowCommand(.getDirectory))
    let request: GlowElement = path.isEmpty ? command : .node(GlowNode(
      .path(path),
      children: [command]
    ))
    try await send(.elements([request]))
    return try await reply(about: path, timeout: timeout)
  }

  /// Sends a matrix connection request and returns the provider's answer for each target.
  public func connect(
    _ connections: [GlowConnection],
    matrix path: GlowPath,
    timeout: Duration = .seconds(5)
  ) async throws -> [GlowConnection] {
    try await send(.elements([.matrix(GlowMatrix(.path(path), connections: connections))]))
    let reply = try await reply(about: path, timeout: timeout) { element in
      guard case let .matrix(matrix) = element else { return false }
      return matrix.address == .path(path) && matrix.connections?
        .contains { $0.disposition != nil } == true
    }
    return reply.flatMap { element -> [GlowConnection] in
      guard case let .matrix(matrix) = element else { return [] }
      return matrix.connections ?? []
    }
  }

  /// The elements of the next message that has an element at or below `path` that
  /// `matching` accepts.
  private func reply(
    about path: GlowPath,
    timeout: Duration,
    matching: @escaping @Sendable (GlowElement) -> Bool = { _ in true }
  ) async throws -> [GlowElement] {
    let root = await inbox.next(timeout: timeout) { root in
      guard case let .elements(elements) = root else { return false }
      return elements.contains { element in
        guard case let .path(elementPath)? = element.address else { return path.isEmpty }
        return elementPath.starts(with: path) && matching(element)
      }
    }
    guard case let .elements(elements)? = root else {
      throw await inbox.isClosed ? Error.closed : Error.timedOut
    }
    return elements
  }

  private static func read(
    _ transport: any EmberPlusTransport,
    into inbox: EmberPlusConsumerInbox,
    logger: Logger
  ) async {
    var deframer = S101.Deframer()
    var reassembler = S101Message.Reassembler()
    defer { Task { await inbox.close() } }
    while !Task.isCancelled {
      guard let bytes = try? await transport.read(), !bytes.isEmpty else { return }
      for case let .message(bytes, framing) in deframer.receive(bytes) {
        guard let message = try? S101Message(decoding: bytes) else { continue }
        switch message.command {
        case let .ember(packet):
          guard case let .message(payload)? = reassembler.receive(packet),
                !payload.isEmpty else { continue }
          do {
            try await inbox.deliver(GlowRoot(decoding: payload))
          } catch {
            logger.debug("undecodable message from \(transport.peerDescription): \(error)")
          }
        case .keepAliveRequest:
          let response = S101Message(slot: message.slot, command: .keepAliveResponse)
          try? await transport.write(S101.frame(response.encoded, framing: framing))
        default:
          break
        }
      }
    }
  }
}

/// What the provider has sent that nobody has asked for yet, and the one request waiting.
private actor EmberPlusConsumerInbox {
  typealias Predicate = @Sendable (GlowRoot) -> Bool

  private var messages = [GlowRoot]()
  private var waiting: (
    id: UInt64,
    predicate: Predicate,
    continuation: CheckedContinuation<GlowRoot?, Never>
  )?
  private var nextID: UInt64 = 0
  private(set) var isClosed = false

  func deliver(_ root: GlowRoot) {
    if let waiting, waiting.predicate(root) {
      self.waiting = nil
      waiting.continuation.resume(returning: root)
    } else {
      messages.append(root)
    }
  }

  func close() {
    isClosed = true
    waiting?.continuation.resume(returning: nil)
    waiting = nil
  }

  func next(timeout: Duration, where predicate: @escaping Predicate) async -> GlowRoot? {
    if let index = messages.firstIndex(where: predicate) { return messages.remove(at: index) }
    guard !isClosed else { return nil }
    nextID += 1
    let id = nextID
    let timer = Task {
      try await Task.sleep(for: timeout)
      self.expire(id)
    }
    defer { timer.cancel() }
    return await withCheckedContinuation { continuation in
      waiting?.continuation.resume(returning: nil)
      waiting = (id, predicate, continuation)
    }
  }

  private func expire(_ id: UInt64) {
    guard let waiting, waiting.id == id else { return }
    self.waiting = nil
    waiting.continuation.resume(returning: nil)
  }
}
