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

/// A host name that does not resolve to an address to connect to.
public struct EmberPlusHostNotFound: Error, Sendable, CustomStringConvertible {
  public let host: String
  public var description: String {
    "\(host): no address to connect to"
  }
}

/// The host's TCP addresses, IPv4 and IPv6, in the resolver's order.
private func tcpAddresses(host: String, port: UInt16) throws -> [sockaddr_storage] {
  var hints = addrinfo()
  hints.ai_family = AF_UNSPEC
  #if canImport(Glibc)
  hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
  #else
  hints.ai_socktype = SOCK_STREAM
  #endif
  var list: UnsafeMutablePointer<addrinfo>?
  guard getaddrinfo(host, String(port), &hints, &list) == 0, let list else {
    throw EmberPlusHostNotFound(host: host)
  }
  defer { freeaddrinfo(list) }
  var addresses = [sockaddr_storage]()
  for info in sequence(first: list, next: { $0.pointee.ai_next }) {
    guard let address = info.pointee.ai_addr,
          [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) else { continue }
    var storage = sockaddr_storage()
    withUnsafeMutableBytes(of: &storage) { storage in
      storage.copyMemory(from: UnsafeRawBufferPointer(
        start: address,
        count: Int(info.pointee.ai_addrlen)
      ))
    }
    addresses.append(storage)
  }
  guard !addresses.isEmpty else { throw EmberPlusHostNotFound(host: host) }
  return addresses
}

#if canImport(IORing)

/// A TCP connection to a provider, through io_uring.
func emberPlusTCPConnection(host: String, port: UInt16) async throws -> any EmberPlusTransport {
  var failure: (any Error)?
  for address in try tcpAddresses(host: host, port: port) {
    do {
      let socket = try Socket(ring: .shared, domain: address.ss_family, type: SOCK_STREAM)
      try await socket.connect(to: address, timeout: .seconds(5))
      try? socket.setTcpNoDelay()
      return EmberPlusIORingTransport(socket)
    } catch {
      failure = error
    }
  }
  throw failure ?? EmberPlusHostNotFound(host: host)
}

#else

/// A TCP connection to a provider, through FlyingSocks.
func emberPlusTCPConnection(host: String, port: UInt16) async throws -> any EmberPlusTransport {
  var failure: (any Error)?
  for storage in try tcpAddresses(host: host, port: port) {
    do {
      var storage = storage
      let socket: AsyncSocket = if Int32(storage.ss_family) == AF_INET6 {
        try await withUnsafeBytes(of: &storage) { $0.load(as: sockaddr_in6.self) }.connected()
      } else {
        try await withUnsafeBytes(of: &storage) { $0.load(as: sockaddr_in.self) }.connected()
      }
      return EmberPlusSocketTransport(socket)
    } catch {
      failure = error
    }
  }
  throw failure ?? EmberPlusHostNotFound(host: host)
}

private extension FlyingSocks.SocketAddress {
  func connected() async throws -> AsyncSocket {
    try await AsyncSocket.connected(to: self)
  }
}

#endif
