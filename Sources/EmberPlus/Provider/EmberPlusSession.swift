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

/// A byte stream to one consumer.
public protocol EmberPlusTransport: Sendable {
  /// The next bytes received, or an empty array at end of stream.
  func read() async throws -> [UInt8]
  func write(_ bytes: [UInt8]) async throws
  func close()
  var peerDescription: String { get }
}

/// One consumer's connection. It deframes and reassembles what the consumer sends, answers
/// keep-alives, passes requests to the tree source in order, and writes messages one at a
/// time, so packets of different messages never interleave.
public final class EmberPlusSession: Sendable, Hashable, CustomStringConvertible {
  private static let nextID = Atomic<UInt64>(1)

  public let id: UInt64
  public let peerDescription: String
  private let transport: any EmberPlusTransport
  private let logger: Logger
  private let outbound: AsyncStream<[UInt8]>.Continuation
  private let outboundStream: AsyncStream<[UInt8]>
  /// The consumer's framing, which replies follow.
  private let framing = Mutex(S101.Framing.escaping)

  init(transport: any EmberPlusTransport, logger: Logger) {
    id = Self.nextID.add(1, ordering: .relaxed).oldValue
    peerDescription = transport.peerDescription
    self.transport = transport
    self.logger = logger
    (outboundStream, outbound) = AsyncStream.makeStream(of: [UInt8].self)
  }

  public var description: String { "EmberPlusSession(\(id), \(peerDescription))" }

  public static func == (lhs: EmberPlusSession, rhs: EmberPlusSession) -> Bool {
    lhs === rhs
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  /// Queues a message for the consumer; it is dropped if the session has ended.
  public func send(_ root: GlowRoot) {
    let framing = framing.withLock { $0 }
    let frames = S101Message.packets(for: root.encoded()).flatMap {
      S101.frame($0.encoded, framing: framing)
    }
    outbound.yield(frames)
  }

  private func send(_ message: S101Message, framing: S101.Framing) {
    outbound.yield(S101.frame(message.encoded, framing: framing))
  }

  /// Serves the consumer until it disconnects.
  func run(source: some EmberPlusTreeSource) async {
    await source.sessionStarted(self)
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await self.writeOutbound() }
      await self.readInbound(source: source)
      outbound.finish()
      transport.close()
      await group.waitForAll()
    }
    await source.sessionEnded(self)
  }

  private func writeOutbound() async {
    for await bytes in outboundStream {
      do {
        try await transport.write(bytes)
      } catch {
        logger.debug("\(self): write failed: \(error)")
        transport.close()
        break
      }
    }
  }

  private func readInbound(source: some EmberPlusTreeSource) async {
    var deframer = S101.Deframer()
    var reassembler = S101Message.Reassembler()
    while !Task.isCancelled {
      let bytes: [UInt8]
      do {
        bytes = try await transport.read()
      } catch {
        logger.debug("\(self): read failed: \(error)")
        return
      }
      guard !bytes.isEmpty else { return }

      for event in deframer.receive(bytes) {
        switch event {
        case let .error(error):
          logger.debug("\(self): \(error)")
        case let .message(bytes, framing):
          self.framing.withLock { $0 = framing }
          let message: S101Message
          do {
            message = try S101Message(decoding: bytes)
          } catch {
            logger.debug("\(self): \(error)")
            continue
          }
          switch message.command {
          case let .ember(packet):
            guard packet.dtd == S101Message.EmberPacket.glowDTD else { continue }
            switch reassembler.receive(packet) {
            case let .message(payload)?:
              guard !payload.isEmpty else { continue }
              await handle(payload, source: source)
            case .discarded?:
              logger.debug("\(self): discarded a partial message")
            case nil:
              break
            }
          case .keepAliveRequest:
            send(S101Message(slot: message.slot, command: .keepAliveResponse), framing: framing)
          default:
            break
          }
        }
      }
    }
  }

  private func handle(_ payload: [UInt8], source: some EmberPlusTreeSource) async {
    let root: GlowRoot
    do {
      root = try GlowRoot(decoding: payload)
    } catch {
      logger.debug("\(self): undecodable message: \(error)")
      return
    }

    var replies = [GlowElement]()
    for request in EmberPlusRequest.requests(in: root) {
      logger.trace("\(self): \(request)")
      switch request {
      case let .getDirectory(path, fieldMask):
        replies += await source.getDirectory(path, fieldMask: fieldMask, session: self)
      case let .setValue(path, value):
        replies += await source.setValue(value, at: path, session: self)
      case let .invoke(path, invocation):
        if let result = await source.invoke(invocation, at: path, session: self) {
          send(.invocationResult(result))
        }
      case let .subscribe(path):
        await source.subscribe(path, session: self)
      case let .unsubscribe(path):
        await source.unsubscribe(path, session: self)
      case let .connect(path, connections):
        replies += await source.connect(connections, matrix: path, session: self)
      }
    }
    if !replies.isEmpty {
      send(.elements(replies))
    }
  }
}
