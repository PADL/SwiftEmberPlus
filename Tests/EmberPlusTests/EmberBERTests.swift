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
// The test vectors were produced with Lawo's libember and libs101, Copyright (C)
// 2012-2019 Lawo GmbH, under the Boost Software License, Version 1.0: see LICENSE.md.
//

@testable import EmberPlus
import XCTest

extension [UInt8] {
  init(hex: String) {
    var bytes = [UInt8]()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      bytes.append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }
    self = bytes
  }

  var hex: String { map { String(format: "%02X", $0) }.joined() }
}

/// REAL and the other universal types against libember (`ber::encodeFrame<double>`).
final class EmberBERTests: XCTestCase {
  // value, then libember's encoding of the whole TLV
  static let realVectors: [(Double, String)] = [
    (0.15625, "090380FD05"),
    (1, "0903800001"),
    (-1, "0903C00001"),
    (0.5, "090380FF01"),
    (2, "0903800101"),
    (3, "0903800103"),
    (-144, "0903C00709"),
    (20, "0903800405"),
    (1e300, "090A8103E405F90F22001D67"),
    (-1e-300, "090AC1FC1B156E1FC2F8F359"),
    (123.456, "090980061EDD2F1A9FBE77"),
    (0.1, "090980FC0CCCCCCCCCCCCD"),
    (1e-10, "090980DE1B7CDFD9D7BDBB"),
    (65535.75, "0905800F03FFFF"),
    (-0.0, "090143"),
    (0, "0900"),
    (.infinity, "090140"),
    (-.infinity, "090141"),
    (.leastNonzeroMagnitude, "090A81FC0110000000000001"),
    (Double(bitPattern: 0x000F_FFFF_FFFF_FFFF), "090A81FC011FFFFFFFFFFFFF"),
    (.greatestFiniteMagnitude, "090A8103FF1FFFFFFFFFFFFF"),
    (.leastNormalMagnitude, "090481FC0201"),
  ]

  func testRealMatchesLibember() {
    for (value, expected) in Self.realVectors {
      let contents = EmberBER.encodeReal(value)
      XCTAssertEqual(([0x09, UInt8(contents.count)] + contents).hex, expected, "\(value)")
    }
  }

  func testRealDecodesLibember() throws {
    for (value, encoded) in Self.realVectors {
      let decoded = try EmberBER.decodeReal([UInt8](hex: encoded).dropFirst(2))
      XCTAssertEqual(decoded.bitPattern, value.bitPattern, "\(encoded)")
    }
  }

  /// The exponent is not X.690's: under X.690, `80 FD 05` would be 5 × 2⁻³ = 0.625.
  func testRealIsNotX690() throws {
    XCTAssertEqual(try EmberBER.decodeReal([0x80, 0xFD, 0x05]), 0.15625)
  }

  func testNaN() throws {
    XCTAssertEqual(EmberBER.encodeReal(.nan), [0x42])
    XCTAssertTrue(try EmberBER.decodeReal([0x42]).isNaN)
    // libember compares with quiet_NaN() (never equal), so encodes NaN as exponent 1024
    XCTAssertTrue(try EmberBER.decodeReal([UInt8](hex: "81040003")).isNaN)
  }

  func testRealRoundTrips() throws {
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<10000 {
      let value = Double(bitPattern: generator.next())
      let decoded = try EmberBER.decodeReal(EmberBER.encodeReal(value))
      if value.isNaN {
        XCTAssertTrue(decoded.isNaN)
      } else {
        XCTAssertEqual(decoded.bitPattern, value.bitPattern)
      }
    }
  }

  func testInteger() throws {
    let vectors: [(Int64, String)] = [
      (0, "00"), (1, "01"), (127, "7F"), (128, "0080"), (255, "00FF"), (256, "0100"),
      (-1, "FF"), (-128, "80"), (-129, "FF7F"), (32, "20"),
      (.max, "7FFFFFFFFFFFFFFF"), (.min, "8000000000000000"),
    ]
    for (value, expected) in vectors {
      XCTAssertEqual(EmberBER.encodeInteger(value).hex, expected)
      XCTAssertEqual(try EmberBER.decodeInteger([UInt8](hex: expected)), value)
    }
    // redundant sign octets are tolerated
    XCTAssertEqual(try EmberBER.decodeInteger([0x00, 0x00, 0x01]), 1)
    XCTAssertEqual(try EmberBER.decodeInteger([0xFF, 0xFF]), -1)
    XCTAssertEqual(try EmberBER.decodeInteger([UInt8](hex: "007FFFFFFFFFFFFFFF")), .max)
  }

  func testIntegerOverflow() {
    XCTAssertThrowsError(try EmberBER.decodeInteger([UInt8](hex: "010000000000000000")))
    XCTAssertThrowsError(try EmberBER.decodeInteger([UInt8](hex: "00FFFFFFFFFFFFFFFF")))
    XCTAssertThrowsError(try EmberBER.decodeInteger32([UInt8](hex: "0080000000")))
    XCTAssertThrowsError(try EmberBER.decodeInteger([]))
  }

  func testRelativeOID() throws {
    let vectors: [([UInt32], String)] = [
      ([1, 2, 3], "010203"), ([1, 300], "01822C"), ([], ""), ([127, 128], "7F8100"),
      ([UInt32.max], "8FFFFFFF7F"),
    ]
    for (arcs, expected) in vectors {
      XCTAssertEqual(EmberBER.encodeRelativeOID(arcs).hex, expected)
      XCTAssertEqual(try EmberBER.decodeRelativeOID([UInt8](hex: expected)), arcs)
    }
    XCTAssertThrowsError(try EmberBER.decodeRelativeOID([0x81]))
    XCTAssertThrowsError(try EmberBER.decodeRelativeOID([0x90, 0x80, 0x80, 0x80, 0x00]))
  }
}
