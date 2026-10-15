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

final class S101Tests: XCTestCase {
  func testCRCTable() {
    XCTAssertEqual(S101.CRC.table[1], 0x1189)
    XCTAssertEqual(S101.CRC.table[255], 0x0F78)
  }

  /// The example in Ember+ Documentation, "Variant 1: Escaping", which libs101 agrees with.
  func testSpecificationExample() {
    XCTAssertEqual(
      S101.frame([0xFF, 0x00, 0xF9, 0x01]).hex,
      "FEFDDF00FDD9019583FF"
    )
    var deframer = S101.Deframer()
    XCTAssertEqual(
      deframer.receive([UInt8](hex: "FEFDDF00FDD9019583FF")),
      [.message([0xFF, 0x00, 0xF9, 0x01], .escaping)]
    )
  }

  func testKeepAliveMatchesLibs101() {
    let message = S101Message(command: .keepAliveRequest)
    XCTAssertEqual(S101.frame(message.encoded).hex, "FE000E010194E4FF")
  }

  func testDeframerSplitsAndJoins() {
    let first = S101.frame([1, 2, 3])
    let second = S101.frame([0xFE, 0xFF, 0xFD, 0xF8])
    let stream = [0x00, 0x01] + first + second
    var deframer = S101.Deframer()
    var events = [S101.Deframer.Event]()
    for byte in stream {
      events += deframer.receive([byte])
    }
    XCTAssertEqual(events, [
      .error(.outOfFrameBytes(2)),
      .message([1, 2, 3], .escaping),
      .message([0xFE, 0xFF, 0xFD, 0xF8], .escaping),
    ])
  }

  func testDeframerResynchronises() {
    var corrupt = S101.frame([1, 2, 3])
    corrupt[2] ^= 0x01
    var deframer = S101.Deframer()
    XCTAssertEqual(
      deframer.receive(corrupt + S101.frame([4])),
      [.error(.crcMismatch), .message([4], .escaping)]
    )
    // a frame cut short by a new BOF
    XCTAssertEqual(
      deframer.receive([S101.bof, 1, 2] + S101.frame([5])),
      [.error(.bofInFrame), .message([5], .escaping)]
    )
  }

  func testNonEscaping() {
    let payload = [UInt8](repeating: 0xFF, count: 10)
    let framed = S101.frame(payload, framing: .nonEscaping)
    XCTAssertEqual(Array(framed.prefix(6)).hex, "F8040000000A")
    var deframer = S101.Deframer()
    XCTAssertEqual(
      deframer.receive(framed + S101.frame([7])),
      [.message(payload, .nonEscaping), .message([7], .escaping)]
    )
  }

  func testMessageHeader() throws {
    let message = S101Message(command: .ember(.init(payload: [0x60, 0x00])))
    XCTAssertEqual(message.encoded.hex, "000E0001C001023202" + "6000")
    XCTAssertEqual(try S101Message(decoding: message.encoded), message)
    XCTAssertEqual(
      try S101Message(decoding: [0x00, 0x0E, 0x01, 0x01]),
      S101Message(command: .keepAliveRequest)
    )
    XCTAssertThrowsError(try S101Message(decoding: [0x00, 0x0F, 0x00, 0x01]))
    XCTAssertThrowsError(try S101Message(decoding: [0x00, 0x0E, 0x00, 0x01, 0xC0, 0x01, 0x05]))
  }

  func testPacketisation() {
    let payload = (0..<3000).map { UInt8(truncatingIfNeeded: $0) }
    let packets = S101Message.packets(for: payload)
    XCTAssertEqual(packets.count, 3)
    var reassembler = S101Message.Reassembler()
    var result: S101Message.Reassembler.Event?
    for packet in packets {
      XCTAssertLessThanOrEqual(packet.encoded.count, S101Message.maximumPacketLength)
      guard case let .ember(ember) = packet.command else { return XCTFail() }
      XCTAssertNil(result)
      result = reassembler.receive(ember)
    }
    XCTAssertEqual(result, .message(payload))

    guard case let .ember(first) = packets[0].command,
          case let .ember(last) = packets[2].command else { return XCTFail() }
    XCTAssertEqual(first.flags, .firstPacket)
    XCTAssertEqual(last.flags, .lastPacket)

    // a middle packet without a first is discarded
    XCTAssertEqual(reassembler.receive(last), .discarded)
  }

  func testEmptyMessage() {
    let packets = S101Message.packets(for: [])
    guard case let .ember(packet) = packets.first?.command else { return XCTFail() }
    XCTAssertEqual(packet.flags, [.singlePacket, .emptyPacket])
    var reassembler = S101Message.Reassembler()
    XCTAssertEqual(reassembler.receive(packet), .message([]))
  }
}
