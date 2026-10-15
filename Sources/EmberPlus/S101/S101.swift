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

/// S101 framing, which carries Ember+ messages over a byte stream (Ember+ Documentation,
/// "Message Framing").
///
/// Variant 1 brackets each message with BOF and EOF, escapes bytes at or above `invalid`
/// and appends an inverted CRC-CCITT16; every provider must speak it. Variant 2 opens with
/// `invalid` followed by a length and is used only with peers that answer a keep-alive in
/// kind.
public enum S101 {
  public static let bof: UInt8 = 0xFE
  public static let eof: UInt8 = 0xFF
  public static let ce: UInt8 = 0xFD
  public static let xor: UInt8 = 0x20
  public static let invalid: UInt8 = 0xF8

  public enum Framing: Sendable, Hashable {
    case escaping
    case nonEscaping
  }

  /// CRC-CCITT16, reflected (polynomial 0x8408), as tabulated in the Ember+ appendix.
  public enum CRC {
    public static let initialValue: UInt16 = 0xFFFF
    /// What the CRC of a frame's data and its own inverted CRC always comes to.
    public static let residue: UInt16 = 0xF0B8

    static let table: [UInt16] = (0..<256).map { byte in
      var crc = UInt16(byte)
      for _ in 0..<8 {
        crc = crc & 1 != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1
      }
      return crc
    }

    @inline(__always)
    public static func update(_ crc: UInt16, _ byte: UInt8) -> UInt16 {
      (crc >> 8) ^ table[Int(UInt8(truncatingIfNeeded: crc) ^ byte)]
    }

    public static func compute(_ bytes: some Sequence<UInt8>, from crc: UInt16 = initialValue)
      -> UInt16
    {
      bytes.reduce(crc, update)
    }
  }

  /// Frames one message.
  public static func frame(_ message: some Collection<UInt8>, framing: Framing = .escaping)
    -> [UInt8]
  {
    switch framing {
    case .escaping:
      var framed = [UInt8]()
      framed.reserveCapacity(message.count + message.count / 8 + 6)
      framed.append(bof)
      func appendEscaped(_ byte: UInt8) {
        if byte >= invalid {
          framed.append(ce)
          framed.append(byte ^ xor)
        } else {
          framed.append(byte)
        }
      }
      message.forEach(appendEscaped)
      let crc = ~CRC.compute(message)
      appendEscaped(UInt8(truncatingIfNeeded: crc))
      appendEscaped(UInt8(truncatingIfNeeded: crc >> 8))
      framed.append(eof)
      return framed
    case .nonEscaping:
      let length = UInt32(message.count)
      var framed: [UInt8] = [invalid, 0x04]
      framed.reserveCapacity(message.count + 6)
      for shift in stride(from: 24, through: 0, by: -8) {
        framed.append(UInt8(truncatingIfNeeded: length >> UInt32(shift)))
      }
      framed.append(contentsOf: message)
      return framed
    }
  }

  public enum FramingError: Error, Sendable, Hashable {
    case outOfFrameBytes(Int)
    case bofInFrame
    case invalidByteInFrame(UInt8)
    case crcMismatch
    case frameTooShort
    case lengthTooLong(Int)
    case frameTooLarge(Int)
  }

  /// Recovers messages from a byte stream that may split or join frames anywhere.
  ///
  /// A framing error loses only the frame it occurs in: the deframer resynchronises on the
  /// next BOF, or on `invalid` outside a frame.
  public struct Deframer: Sendable {
    public enum Event: Sendable, Hashable {
      case message([UInt8], Framing)
      case error(FramingError)
    }

    private enum State: Sendable {
      case outside(skipped: Int)
      case escaping(crc: UInt16, escaped: Bool)
      case lengthPrefix
      case length(remaining: Int, value: Int)
      case payload(length: Int)
    }

    private var state = State.outside(skipped: 0)
    private var buffer = [UInt8]()
    public let maximumMessageSize: Int

    public init(maximumMessageSize: Int = 16 * 1024 * 1024) {
      self.maximumMessageSize = maximumMessageSize
    }

    public mutating func receive(_ bytes: some Sequence<UInt8>) -> [Event] {
      var events = [Event]()
      for byte in bytes {
        if let event = receive(byte) { events.append(event) }
      }
      return events
    }

    public mutating func receive(_ byte: UInt8) -> Event? {
      switch state {
      case let .outside(skipped):
        if byte == S101.bof || byte == S101.invalid {
          buffer.removeAll(keepingCapacity: true)
          state = byte == S101.bof ? .escaping(crc: CRC.initialValue, escaped: false) :
            .lengthPrefix
          if skipped > 0 { return .error(.outOfFrameBytes(skipped)) }
        } else {
          state = .outside(skipped: skipped + 1)
        }
        return nil

      case let .escaping(crc, escaped):
        switch byte {
        case S101.bof:
          buffer.removeAll(keepingCapacity: true)
          state = .escaping(crc: CRC.initialValue, escaped: false)
          return .error(.bofInFrame)
        case S101.eof:
          state = .outside(skipped: 0)
          guard buffer.count >= 3 else { return .error(.frameTooShort) }
          guard crc == CRC.residue else { return .error(.crcMismatch) }
          return .message(Array(buffer.dropLast(2)), .escaping)
        case S101.ce:
          state = .escaping(crc: crc, escaped: true)
          return nil
        case S101.invalid...:
          state = .outside(skipped: 0)
          return .error(.invalidByteInFrame(byte))
        default:
          let byte = escaped ? byte ^ S101.xor : byte
          guard buffer.count < maximumMessageSize + 2 else {
            state = .outside(skipped: 0)
            return .error(.frameTooLarge(buffer.count))
          }
          buffer.append(byte)
          state = .escaping(crc: CRC.update(crc, byte), escaped: false)
          return nil
        }

      case .lengthPrefix:
        let count = Int(byte & 0x07)
        guard count > 0 else {
          state = .outside(skipped: 0)
          return .message([], .nonEscaping)
        }
        state = .length(remaining: count, value: 0)
        return nil

      case let .length(remaining, value):
        guard value <= (Int.max >> 8) else {
          state = .outside(skipped: 0)
          return .error(.lengthTooLong(value))
        }
        let value = value << 8 | Int(byte)
        if remaining > 1 {
          state = .length(remaining: remaining - 1, value: value)
          return nil
        }
        guard value <= maximumMessageSize else {
          state = .outside(skipped: 0)
          return .error(.frameTooLarge(value))
        }
        if value == 0 {
          state = .outside(skipped: 0)
          return .message([], .nonEscaping)
        }
        buffer.reserveCapacity(value)
        state = .payload(length: value)
        return nil

      case let .payload(length):
        buffer.append(byte)
        guard buffer.count == length else { return nil }
        state = .outside(skipped: 0)
        return .message(buffer, .nonEscaping)
      }
    }
  }
}
