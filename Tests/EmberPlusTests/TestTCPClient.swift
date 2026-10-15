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
import Synchronization

/// A consumer connected over TCP on loopback, through the same backend as the provider.
final class TestTCPClient: Sendable {
  #if canImport(IORing)
  /// The descriptor is closed when the socket goes, which `close()` makes happen.
  private let socket: Mutex<Socket?>

  init(port: UInt16) async throws {
    let socket = try Socket(ring: .shared, domain: sa_family_t(AF_INET6), type: SOCK_STREAM)
    var address = sockaddr_in6()
    address.sin6_family = sa_family_t(AF_INET6)
    address.sin6_port = port.bigEndian
    address.sin6_addr = in6addr_loopback
    try await socket.connect(to: address)
    self.socket = Mutex(socket)
  }

  private var connected: Socket {
    get throws {
      guard let socket = socket.withLock({ $0 }) else { throw CancellationError() }
      return socket
    }
  }

  func write(_ bytes: [UInt8]) async throws {
    _ = try await connected.write(bytes, count: bytes.count, awaitingAllWritten: true)
  }

  func read() async throws -> [UInt8] {
    try await connected.read(count: 4096, awaitingAllRead: false)
  }

  func close() {
    socket.withLock { $0 = nil }
  }
  #else
  private let socket: AsyncSocket

  init(port: UInt16) async throws {
    socket = try await AsyncSocket.connected(to: .loopback(port: port))
  }

  func write(_ bytes: [UInt8]) async throws {
    try await socket.write(Data(bytes))
  }

  func read() async throws -> [UInt8] {
    do {
      return try await socket.read(atMost: 4096)
    } catch SocketError.disconnected {
      return []
    }
  }

  func close() {
    try? socket.close()
  }
  #endif
}
