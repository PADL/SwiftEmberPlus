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

import FlyingSocks
import Foundation
import Logging

/// An Ember+ provider listening on TCP, serving one tree source to any number of consumers.
public final class EmberPlusProvider<Source: EmberPlusTreeSource>: Sendable {
  /// The port Lawo devices conventionally use.
  public static var defaultPort: UInt16 { 9000 }

  public let source: Source
  public let port: UInt16
  private let logger: Logger

  public init(
    source: Source,
    port: UInt16 = defaultPort,
    logger: Logger = Logger(label: "com.padl.EmberPlus.EmberPlusProvider")
  ) {
    self.source = source
    self.port = port
    self.logger = logger
  }

  /// Listens on all interfaces until cancelled.
  public func run() async throws {
    let pool = SocketPool.make()
    try await pool.prepare()
    let socket = try Socket(domain: AF_INET6)
    try socket.setValue(true, for: .localAddressReuse)
    #if canImport(Darwin)
    try socket.setValue(true, for: .noSIGPIPE)
    #endif
    try socket.bind(to: .inet6(port: port))
    try socket.listen()
    logger.info("Ember+ provider listening on port \(port)")
    try await serve(listener: AsyncSocket(socket: socket, pool: pool), pool: pool)
  }

  func serve(listener: AsyncSocket, pool: some AsyncSocketPool) async throws {
    defer { try? listener.close() }
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await pool.run() }
      group.addTask {
        try await withThrowingDiscardingTaskGroup { sessions in
          for try await socket in listener.sockets {
            sessions.addTask {
              await self.serve(EmberPlusSocketTransport(socket))
            }
          }
        }
      }
      try await group.next()
      group.cancelAll()
    }
  }

  /// Serves one consumer over any transport until it disconnects.
  public func serve(_ transport: some EmberPlusTransport) async {
    let session = EmberPlusSession(transport: transport, logger: logger)
    logger.debug("\(session) connected")
    await session.run(source: source)
    logger.debug("\(session) disconnected")
  }
}

struct EmberPlusSocketTransport: EmberPlusTransport {
  let socket: AsyncSocket
  let peerDescription: String

  init(_ socket: AsyncSocket) {
    self.socket = socket
    peerDescription = switch try? socket.socket.remotePeer() {
    case let .ip4(address, port)?: "\(address):\(port)"
    case let .ip6(address, port)?: "[\(address)]:\(port)"
    case let .unix(path)?: path
    case nil: "unknown"
    }
  }

  func read() async throws -> [UInt8] {
    do {
      return try await socket.read(atMost: 4096)
    } catch SocketError.disconnected {
      return []
    }
  }

  func write(_ bytes: [UInt8]) async throws {
    try await socket.write(Data(bytes))
  }

  func close() {
    try? socket.close()
  }
}
