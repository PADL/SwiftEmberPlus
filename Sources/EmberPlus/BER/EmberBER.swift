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

/// The contents octets of the universal types Glow uses, as libember encodes them.
///
/// swift-asn1 parses BER (indefinite lengths included) and serialises DER, which Ember+
/// accepts; it knows neither REAL nor RELATIVE-OID, which are here.
public enum EmberBER {
  public enum DecodingError: Error, Sendable, Hashable {
    case invalidInteger
    case integerOverflow
    case invalidBoolean
    case invalidReal
    case invalidRelativeOID
    case invalidUTF8
  }

  // MARK: INTEGER

  public static func encodeInteger(_ value: Int64) -> [UInt8] {
    var length = 8
    // drop leading bytes that only repeat the sign of the next
    while length > 1 {
      let top = UInt8(truncatingIfNeeded: value >> Int64((length - 1) * 8))
      let next = UInt8(truncatingIfNeeded: value >> Int64((length - 2) * 8))
      guard (top == 0x00 && next & 0x80 == 0) || (top == 0xFF && next & 0x80 != 0) else { break }
      length -= 1
    }
    return (0..<length).reversed().map { UInt8(truncatingIfNeeded: value >> Int64($0 * 8)) }
  }

  /// Accepts redundant leading sign octets, which X.690 forbids but some encoders emit.
  public static func decodeInteger(_ bytes: some Collection<UInt8>) throws -> Int64 {
    guard let first = bytes.first else { throw DecodingError.invalidInteger }
    let fill: UInt8 = first & 0x80 != 0 ? 0xFF : 0x00
    var significant = bytes[...]
    while significant.count > 8, significant.first == fill {
      significant = significant.dropFirst()
    }
    guard significant.count <= 8 else { throw DecodingError.integerOverflow }
    var value: Int64 = first & 0x80 != 0 ? -1 : 0
    for byte in significant {
      value = value << 8 | Int64(byte)
    }
    if let top = significant.first, top & 0x80 != fill & 0x80 { throw DecodingError.integerOverflow }
    return value
  }

  public static func decodeInteger32(_ bytes: some Collection<UInt8>) throws -> Int32 {
    guard let value = try Int32(exactly: decodeInteger(bytes)) else {
      throw DecodingError.integerOverflow
    }
    return value
  }

  // MARK: BOOLEAN

  public static func encodeBoolean(_ value: Bool) -> [UInt8] { [value ? 0xFF : 0x00] }

  public static func decodeBoolean(_ bytes: some Collection<UInt8>) throws -> Bool {
    guard bytes.count == 1, let byte = bytes.first else { throw DecodingError.invalidBoolean }
    return byte != 0
  }

  // MARK: REAL

  /// Encodes a REAL as libember, EmberLib.net and libember_slim all do.
  ///
  /// Their exponent is the unbiased IEEE 754 exponent, and the mantissa is the significand
  /// with its implied leading one and without trailing zero bits. That places the binary
  /// point after the mantissa's leading one, where X.690 places it after the last bit, so
  /// 0.15625 is `80 FD 05` here and `80 FB 05` under X.690. Lawo acknowledged this as a bug
  /// but kept it for compatibility with deployed devices (ember-plus-discuss, "Real value
  /// encoding"), so it is reproduced exactly, in both directions.
  public static func encodeReal(_ value: Double) -> [UInt8] {
    if value.isNaN { return [0x42] }
    if value == .infinity { return [0x40] }
    if value == -.infinity { return [0x41] }
    if value == 0 { return value.sign == .minus ? [0x43] : [] }

    let bits = value.bitPattern
    let exponent = Int64((bits & 0x7FF0_0000_0000_0000) >> 52) - 1023
    var mantissa = (bits & 0x000F_FFFF_FFFF_FFFF) | 0x0010_0000_0000_0000
    while mantissa & 0xFF == 0 { mantissa >>= 8 }
    while mantissa & 0x01 == 0 { mantissa >>= 1 }

    let exponentBytes = encodeInteger(exponent)
    var preamble = 0x80 | UInt8(exponentBytes.count - 1)
    if bits & 0x8000_0000_0000_0000 != 0 { preamble |= 0x40 }
    // the mantissa is at most 53 bits, so it is positive as an Int64
    return [preamble] + exponentBytes + encodeInteger(Int64(mantissa))
  }

  /// Decodes a REAL with libember's exponent convention (see `encodeReal(_:)`).
  public static func decodeReal(_ bytes: some Collection<UInt8>) throws -> Double {
    guard let preamble = bytes.first else { return 0 }
    if bytes.count == 1 {
      switch preamble {
      case 0x40: return .infinity
      case 0x41: return -.infinity
      case 0x42: return .nan
      case 0x43: return -0.0
      default: break
      }
    }
    // decimal encodings, which no Ember+ implementation emits
    guard preamble & 0x80 != 0 else { throw DecodingError.invalidReal }

    let exponentLength = 1 + Int(preamble & 0x03)
    let mantissaShift = UInt64((preamble >> 2) & 0x03)
    let rest = bytes.dropFirst()
    guard rest.count > exponentLength, exponentLength <= 8 else { throw DecodingError.invalidReal }
    let exponent = try decodeInteger(rest.prefix(exponentLength))
    let mantissaBytes = rest.dropFirst(exponentLength)
    guard mantissaBytes.count <= 8 else { throw DecodingError.invalidReal }
    var mantissa = mantissaBytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } << mantissaShift

    if mantissa != 0 {
      while mantissa & 0x7FFF_F000_0000_0000 == 0 { mantissa <<= 8 }
      while mantissa & 0x7FF0_0000_0000_0000 == 0 { mantissa <<= 1 }
    }
    mantissa &= 0x000F_FFFF_FFFF_FFFF
    var bits = UInt64(bitPattern: (exponent &+ 1023) << 52) | mantissa
    if preamble & 0x40 != 0 { bits |= 0x8000_0000_0000_0000 }
    return Double(bitPattern: bits)
  }

  // MARK: RELATIVE-OID

  public static func encodeRelativeOID(_ arcs: [UInt32]) -> [UInt8] {
    var bytes = [UInt8]()
    for arc in arcs {
      var septets = [UInt8(arc & 0x7F)]
      var remainder = arc >> 7
      while remainder != 0 {
        septets.append(UInt8(remainder & 0x7F) | 0x80)
        remainder >>= 7
      }
      bytes.append(contentsOf: septets.reversed())
    }
    return bytes
  }

  public static func decodeRelativeOID(_ bytes: some Collection<UInt8>) throws -> [UInt32] {
    var arcs = [UInt32]()
    var arc: UInt32 = 0
    var pending = false
    for byte in bytes {
      guard arc >> 25 == 0 else { throw DecodingError.invalidRelativeOID }
      arc = arc << 7 | UInt32(byte & 0x7F)
      pending = byte & 0x80 != 0
      if !pending {
        arcs.append(arc)
        arc = 0
      }
    }
    guard !pending else { throw DecodingError.invalidRelativeOID }
    return arcs
  }

  // MARK: UTF8String

  public static func decodeUTF8(_ bytes: some Collection<UInt8>) throws -> String {
    guard let string = String(validating: bytes, as: UTF8.self) else {
      throw DecodingError.invalidUTF8
    }
    return string
  }
}
