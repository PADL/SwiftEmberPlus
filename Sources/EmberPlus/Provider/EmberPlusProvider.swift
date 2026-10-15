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

#if canImport(IORing)
import Glibc
import IORing
import IORingUtils
import SocketAddress
#else
import FlyingSocks
#endif
import Foundation
import Logging
import Synchronization

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
  ///
  /// On Linux a write to a consumer that has gone raises SIGPIPE, as io_uring writes cannot
  /// ask for MSG_NOSIGNAL, so the program must ignore or handle it.
  public func run() async throws {
    let listener = try EmberPlusListener(port: port)
    logger.info("Ember+ provider listening on port \(port)")
    try await serve(listener: listener)
  }

  func serve(listener: EmberPlusListener) async throws {
    try await listener.run { await self.serve($0) }
  }

  /// Serves one consumer over any transport until it disconnects.
  public func serve(_ transport: some EmberPlusTransport) async {
    let session = EmberPlusSession(transport: transport, logger: logger)
    logger.debug("\(session) connected")
    await session.run(source: source)
    logger.debug("\(session) disconnected")
  }
}

#if canImport(IORing)

/// A listening IPv6 socket (taking IPv4 too, unless the host says otherwise), whose
/// consumers io_uring accepts, reads and writes.
struct EmberPlusListener: Sendable {
  private let socket: Socket
  /// The port bound, which is the one asked for unless that was 0.
  let port: UInt16

  init(port: UInt16, loopback: Bool = false, ring: IORing = .shared) throws {
    let socket = try Socket(ring: ring, domain: sa_family_t(AF_INET6), type: SOCK_STREAM)
    try socket.setReuseAddr()
    // inherited by the sockets accepted: the meter stream is small messages
    try socket.setTcpNoDelay()
    var address = sockaddr_in6()
    address.sin6_family = sa_family_t(AF_INET6)
    address.sin6_port = port.bigEndian
    if loopback { address.sin6_addr = in6addr_loopback }
    try socket.bind(to: address)
    try socket.listen()
    self.socket = socket
    self.port = try socket.localAddress.port
  }

  /// Accepts consumers, serving each in a task of its own, until cancelled.
  func run(_ serve: @escaping @Sendable (EmberPlusIORingTransport) async -> ()) async throws {
    try await withThrowingDiscardingTaskGroup { sessions in
      // a multishot accept, rearmed should the kernel end it
      while !Task.isCancelled {
        do {
          for try await socket in try await socket.accept() {
            sessions.addTask { await serve(EmberPlusIORingTransport(socket)) }
          }
        } catch where Task.isCancelled {
          break
        }
      }
    }
  }
}

struct EmberPlusIORingTransport: EmberPlusTransport {
  let socket: Socket
  let peerDescription: String

  init(_ socket: Socket) {
    self.socket = socket
    peerDescription = (try? socket.peerName) ?? "unknown"
    // a consumer that vanishes without a FIN is noticed in two minutes, not hours
    for (level, option, value) in Self.keepAliveOptions {
      try? socket.setIntegerOption(level: level, option: option, to: value)
    }
  }

  /// As SwiftOCA's `OcaTcpKeepAlive`: probes after 60 s idle, every 10 s, 6 times, with
  /// unacknowledged writes failing after the same 120 s.
  private static let keepAliveOptions: [(CInt, CInt, CInt)] = [
    (SOL_SOCKET, SO_KEEPALIVE, 1),
    (CInt(IPPROTO_TCP), TCP_KEEPIDLE, 60),
    (CInt(IPPROTO_TCP), TCP_KEEPINTVL, 10),
    (CInt(IPPROTO_TCP), TCP_KEEPCNT, 6),
    (CInt(IPPROTO_TCP), TCP_USER_TIMEOUT, 120_000),
  ]

  func read() async throws -> [UInt8] {
    // empty at the end of the stream
    try await socket.read(count: 4096, awaitingAllRead: false)
  }

  func write(_ bytes: [UInt8]) async throws {
    _ = try await socket.write(bytes, count: bytes.count, awaitingAllWritten: true)
  }

  /// Shuts the socket down rather than closing it, so a read in flight ends with the
  /// stream; the descriptor is closed when the last reference goes.
  func close() {
    try? socket.shutdown()
  }
}

#else

/// A listening IPv6 socket (taking IPv4 too, unless the host says otherwise), whose
/// consumers FlyingSocks accepts, reads and writes.
struct EmberPlusListener: Sendable {
  private let socket: Socket
  /// The port bound, which is the one asked for unless that was 0.
  let port: UInt16

  init(port: UInt16, loopback: Bool = false) throws {
    let socket = try Socket(domain: AF_INET6)
    try socket.setValue(true, for: .localAddressReuse)
    #if canImport(Darwin)
    try socket.setValue(true, for: .noSIGPIPE)
    #endif
    try socket.bind(to: loopback ? .loopback(port: port) : .inet6(port: port))
    try socket.listen()
    guard case let .ip6(_, port) = try socket.sockname() else {
      throw SocketError.unsupportedAddress
    }
    self.socket = socket
    self.port = port
  }

  /// Accepts consumers, serving each in a task of its own, until cancelled.
  func run(_ serve: @escaping @Sendable (EmberPlusSocketTransport) async -> ()) async throws {
    let pool = SocketPool.make()
    try await pool.prepare()
    let listener = try AsyncSocket(socket: socket, pool: pool)
    defer { try? listener.close() }
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await pool.run() }
      group.addTask {
        try await withThrowingDiscardingTaskGroup { sessions in
          for try await socket in listener.sockets {
            sessions.addTask { await serve(EmberPlusSocketTransport(socket)) }
          }
        }
      }
      try await group.next()
      group.cancelAll()
    }
  }
}

/// A consumer's connection. Closing it shuts the socket down rather than closing it,
/// because closing a socket does not wake a read already waiting on it, where shutting
/// it down makes it readable at its end; the read that sees the end closes it. The socket
/// is closed once, so a descriptor the system has since reused is never shut down.
final class EmberPlusSocketTransport: EmberPlusTransport {
  private enum State {
    case open
    case shutDown
    case closed
  }

  let socket: AsyncSocket
  let peerDescription: String
  private let state = Mutex(State.open)

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
    guard state.withLock({ $0 }) != .closed else { return [] }
    do {
      let bytes = try await socket.read(atMost: 4096)
      if bytes.isEmpty { closeSocket() }
      return bytes
    } catch SocketError.disconnected {
      closeSocket()
      return []
    } catch {
      // a shut down socket may fail its read rather than end it
      guard state.withLock({ $0 }) == .open else {
        closeSocket()
        return []
      }
      throw error
    }
  }

  func write(_ bytes: [UInt8]) async throws {
    try await socket.write(Data(bytes))
  }

  func close() {
    state.withLock { state in
      guard state == .open else { return }
      _ = shutdown(socket.socket.file.rawValue, Int32(SHUT_RDWR))
      state = .shutDown
    }
  }

  private func closeSocket() {
    state.withLock { state in
      guard state != .closed else { return }
      try? socket.close()
      state = .closed
    }
  }

  deinit {
    closeSocket()
  }
}

#endif
