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
// Portions derived from Lawo's Ember+, Copyright (C) 2012-2019 Lawo GmbH, under the
// Boost Software License, Version 1.0: see LICENSE.md.
//

/// What one S101 frame carries: a slot, the message type (always EmBER) and a command,
/// with, for an EmBER packet, the flags that partition a long message across packets.
public struct S101Message: Sendable, Hashable {
  public static let emberMessageType: UInt8 = 0x0E
  public static let version: UInt8 = 0x01
  /// The largest unframed packet a peer is expected to accept, header included.
  public static let maximumPacketLength = 1024

  public struct Flags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let firstPacket = Flags(rawValue: 0x80)
    public static let lastPacket = Flags(rawValue: 0x40)
    public static let emptyPacket = Flags(rawValue: 0x20)
    public static let singlePacket: Flags = [.firstPacket, .lastPacket]
  }

  public struct EmberPacket: Sendable, Hashable {
    public var flags: Flags
    public var dtd: UInt8
    public var appBytes: [UInt8]
    public var payload: [UInt8]

    public static let glowDTD: UInt8 = 0x01
    /// Glow DTD 2.50, minor version first, as the slot's application bytes report it.
    public static let glowAppBytes: [UInt8] = [50, 2]

    public init(
      flags: Flags = .singlePacket,
      dtd: UInt8 = glowDTD,
      appBytes: [UInt8] = glowAppBytes,
      payload: [UInt8]
    ) {
      self.flags = flags
      self.dtd = dtd
      self.appBytes = appBytes
      self.payload = payload
    }
  }

  public enum Command: Sendable, Hashable {
    case ember(EmberPacket)
    case keepAliveRequest
    case keepAliveResponse
    case providerState(UInt8)
    case other(UInt8, [UInt8])

    var number: UInt8 {
      switch self {
      case .ember: 0x00
      case .keepAliveRequest: 0x01
      case .keepAliveResponse: 0x02
      case .providerState: 0x03
      case let .other(number, _): number
      }
    }
  }

  public enum DecodingError: Error, Sendable, Hashable {
    case truncated
    case unsupportedMessageType(UInt8)
  }

  public var slot: UInt8
  public var command: Command

  public init(slot: UInt8 = 0, command: Command) {
    self.slot = slot
    self.command = command
  }

  public init(decoding bytes: some Collection<UInt8>) throws {
    var bytes = bytes[...]
    func next() throws -> UInt8 {
      guard let byte = bytes.popFirst() else { throw DecodingError.truncated }
      return byte
    }
    slot = try next()
    let messageType = try next()
    guard messageType == Self.emberMessageType else {
      throw DecodingError.unsupportedMessageType(messageType)
    }
    let command = try next()
    // the version byte is not checked, as other implementations do not check it
    _ = try next()
    switch command {
    case 0x00:
      let flags = try Flags(rawValue: next())
      let dtd = try next()
      let appBytesCount = try Int(next())
      guard bytes.count >= appBytesCount else { throw DecodingError.truncated }
      let appBytes = Array(bytes.prefix(appBytesCount))
      self.command = .ember(EmberPacket(
        flags: flags,
        dtd: dtd,
        appBytes: appBytes,
        payload: Array(bytes.dropFirst(appBytesCount))
      ))
    case 0x01:
      self.command = .keepAliveRequest
    case 0x02:
      self.command = .keepAliveResponse
    case 0x03:
      self.command = try .providerState(next())
    default:
      self.command = .other(command, Array(bytes))
    }
  }

  public var encoded: [UInt8] {
    var bytes: [UInt8] = [slot, Self.emberMessageType, command.number, Self.version]
    switch command {
    case let .ember(packet):
      bytes.reserveCapacity(7 + packet.appBytes.count + packet.payload.count)
      bytes.append(packet.flags.rawValue)
      bytes.append(packet.dtd)
      bytes.append(UInt8(packet.appBytes.count))
      bytes.append(contentsOf: packet.appBytes)
      bytes.append(contentsOf: packet.payload)
    case .keepAliveRequest, .keepAliveResponse:
      break
    case let .providerState(state):
      bytes.append(state)
    case let .other(_, data):
      bytes.append(contentsOf: data)
    }
    return bytes
  }

  /// Divides an encoded Glow message into packets no longer than `maximumPacketLength`
  /// before framing. Only an empty message produces an empty packet.
  public static func packets(
    for payload: [UInt8],
    slot: UInt8 = 0,
    dtd: UInt8 = EmberPacket.glowDTD,
    appBytes: [UInt8] = EmberPacket.glowAppBytes,
    maximumPacketLength: Int = maximumPacketLength
  ) -> [S101Message] {
    let headerLength = 7 + appBytes.count
    precondition(maximumPacketLength > headerLength)
    guard !payload.isEmpty else {
      return [S101Message(slot: slot, command: .ember(EmberPacket(
        flags: [.singlePacket, .emptyPacket],
        dtd: dtd,
        appBytes: appBytes,
        payload: []
      )))]
    }
    let chunkLength = maximumPacketLength - headerLength
    let starts = Array(stride(from: 0, to: payload.count, by: chunkLength))
    return starts.enumerated().map { index, start in
      var flags = Flags()
      if index == 0 { flags.insert(.firstPacket) }
      if index == starts.count - 1 { flags.insert(.lastPacket) }
      return S101Message(slot: slot, command: .ember(EmberPacket(
        flags: flags,
        dtd: dtd,
        appBytes: appBytes,
        payload: Array(payload[start..<min(start + chunkLength, payload.count)])
      )))
    }
  }

  /// Rejoins the payloads of a message partitioned across EmBER packets.
  public struct Reassembler: Sendable {
    public enum Event: Sendable, Hashable {
      case message([UInt8])
      /// A packet arrived out of sequence and the partial message was discarded.
      case discarded
    }

    private var buffer: [UInt8]?
    public let maximumMessageSize: Int

    public init(maximumMessageSize: Int = 16 * 1024 * 1024) {
      self.maximumMessageSize = maximumMessageSize
    }

    public mutating func receive(_ packet: EmberPacket) -> Event? {
      let payload = packet.flags.contains(.emptyPacket) ? [] : packet.payload
      if packet.flags.contains(.firstPacket) {
        let interrupted = buffer != nil
        buffer = payload
        if packet.flags.contains(.lastPacket) {
          defer { buffer = nil }
          return .message(payload)
        }
        return interrupted ? .discarded : nil
      }
      guard buffer != nil else { return .discarded }
      buffer!.append(contentsOf: payload)
      if buffer!.count > maximumMessageSize {
        buffer = nil
        return .discarded
      }
      if packet.flags.contains(.lastPacket) {
        defer { buffer = nil }
        return .message(buffer!)
      }
      return nil
    }
  }
}
