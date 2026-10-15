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
import SwiftASN1
import XCTest

/// Glow messages against libember 2.50, which encodes fields in the order they are set and
/// so in tag order here.
final class GlowCodingTests: XCTestCase {
  static let vectors: [(String, GlowRoot, String)] = [
    (
      "GetDirectory on the root",
      .elements([.command(GlowCommand(.getDirectory))]),
      "600B6B09A0076205A003020120"
    ),
    (
      "GetDirectory on a qualified node",
      .elements([.node(GlowNode(
        .path([1, 2]),
        children: [.command(GlowCommand(.getDirectory, dirFieldMask: .all))]
      ))]),
      "601E6B1CA01A6A18A0040D020102A210640EA00C620AA003020120A1030201FF"
    ),
    (
      "a nested value change",
      .elements([.node(GlowNode(
        .number(1),
        children: [.parameter(GlowParameter(
          .number(2),
          contents: GlowParameterContents(value: .string("hi"))
        ))]
      ))]),
      "60226B20A01E631CA003020101A2156413A011610FA003020102A1083106A2040C026869"
    ),
    (
      "a described real parameter",
      .elements([.parameter(GlowParameter(.path([1, 2, 3]), contents: GlowParameterContents(
        identifier: "gain",
        description: "Gain",
        value: .real(0.15625),
        minimum: .real(-144),
        maximum: .real(20),
        access: .readWrite,
        format: "%.1f dB",
        isOnline: true,
        type: .real
      )))]),
      "60506B4EA04C694AA0050D03010203A141313FA0060C046761696EA1060C044761696EA205090380FD05"
        + "A3050903C00709A4050903800405A503020103A6090C07252E3166206442A9030101FFAD03020102"
    ),
    (
      "an enumerated parameter",
      .elements([.parameter(GlowParameter(.path([1, 300]), contents: GlowParameterContents(
        identifier: "mute",
        value: .integer(1),
        minimum: .integer(0),
        maximum: .integer(2),
        access: .readWrite,
        type: .enum,
        enumMap: [GlowStringIntegerPair("Muted", 1), GlowStringIntegerPair("Unmuted", 2)]
      )))]),
      "605C6B5AA0586956A0050D0301822CA14D314BA0060C046D757465A203020101A303020100A403020102"
        + "A503020103AD03020106AF286826A010670EA0070C054D75746564A103020101A0126710A0090C07556E"
        + "6D75746564A103020102"
    ),
    (
      "a described node",
      .elements([.node(GlowNode(.path([1]), contents: GlowNodeContents(
        identifier: "Root",
        description: "Root block",
        isRoot: true,
        isOnline: true
      )))]),
      "602F6B2DA02B6A29A0030D0101A1223120A0060C04526F6F74A10C0C0A526F6F7420626C6F636BA20301"
        + "01FFA3030101FF"
    ),
    (
      "streams",
      .streams([
        GlowStreamEntry(streamIdentifier: 110, value: .real(-20.5)),
        GlowStreamEntry(streamIdentifier: 111, value: .integer(42)),
      ]),
      "6020661EA00E650CA00302016EA1050903C00429A00C650AA00302016FA10302012A"
    ),
  ]

  func testEncodingMatchesLibember() {
    for (name, root, expected) in Self.vectors {
      XCTAssertEqual(root.encoded().hex, expected, name)
    }
  }

  func testDecodingLibember() throws {
    for (name, root, encoded) in Self.vectors {
      XCTAssertEqual(try GlowRoot(decoding: [UInt8](hex: encoded)), root, name)
    }
  }

  /// EmberLib.net and libember_slim write every container with an indefinite length.
  func testIndefiniteLengths() throws {
    let encoded = [UInt8](hex: "60806B80A0806280A003020120" + "0000000000000000")
    XCTAssertEqual(
      try GlowRoot(decoding: encoded),
      .elements([.command(GlowCommand(.getDirectory))])
    )
  }

  /// libember writes lengths over 127 in three octets whether or not they need them.
  func testNonMinimalLengths() throws {
    let encoded = [UInt8](
      hex: "6082009C6B820098A082009471820090A0030D0102A13C313AA0080C06726F75746572A203020102A4"
        + "03020104A503020104A8050D03028768AA183016A0147212A0050D03028769A1090C075072696D6172"
        + "79A3143012A0076E05A003020100A0076E05A003020101A41D301BA0076F05A003020100A0076F05A0"
        + "03020101A0076F05A003020102A5163014A0127010A003020100A1040D020102A303020101"
    )
    XCTAssertEqual(try GlowRoot(decoding: encoded), .elements([.matrix(GlowMatrix(
      .path([2]),
      contents: GlowMatrixContents(
        identifier: "router",
        type: .nToN,
        targetCount: 4,
        sourceCount: 4,
        parametersLocation: .basePath([2, 1000]),
        labels: [GlowLabel(basePath: [2, 1001], description: "Primary")]
      ),
      targets: [0, 1],
      sources: [0, 1, 2],
      connections: [GlowConnection(target: 0, sources: [1, 2], disposition: .modified)]
    ))]))
  }

  func testUnknownFieldsAndElementsAreSkipped() throws {
    var serializer = DER.Serializer()
    serializer.appendApplication(GlowTag.root) {
      $0.appendApplication(GlowTag.rootElementCollection) { collection in
        collection.appendContext(0) {
          $0.appendApplication(GlowTag.node) { node in
            node.appendField(0, integer: Int32(1))
            node.appendContext(1) {
              $0.appendSet {
                $0.appendField(0, string: "a")
                $0.appendField(30, integer: Int32(0))
              }
            }
            node.appendContext(9) { $0.appendNull() }
          }
        }
        // an element type from a later DTD
        collection.appendContext(0) {
          $0.appendApplication(30) { $0.appendField(0, integer: Int32(1)) }
        }
      }
    }
    XCTAssertEqual(
      try GlowRoot(decoding: serializer.serializedBytes),
      .elements([.node(GlowNode(.number(1), contents: GlowNodeContents(identifier: "a")))])
    )
  }

  func testRoundTrips() throws {
    let roots: [GlowRoot] = [
      .elements([.function(GlowFunction(.path([1, 4]), contents: GlowFunctionContents(
        identifier: "add",
        arguments: [GlowTupleItemDescription(type: .integer, name: "a"),
                    GlowTupleItemDescription(type: .integer)],
        result: [GlowTupleItemDescription(type: .integer, name: "sum")]
      )))]),
      .elements([.function(GlowFunction(.path([1, 4]), children: [
        .command(GlowCommand(.invoke, invocation: GlowInvocation(
          invocationID: 7,
          arguments: [.integer(1), .integer(2)]
        ))),
      ]))]),
      .invocationResult(GlowInvocationResult(invocationID: 7, success: true, result: [.integer(3)])),
      .elements([.matrix(GlowMatrix(
        .path([2]),
        contents: GlowMatrixContents(
          identifier: "router",
          type: .nToN,
          targetCount: 4,
          sourceCount: 4,
          parametersLocation: .basePath([2, 1000]),
          labels: [GlowLabel(basePath: [2, 1001], description: "Primary")]
        ),
        targets: [0, 1],
        sources: [0, 1, 2],
        connections: [GlowConnection(target: 0, sources: [1, 2], disposition: .modified)]
      ))]),
      .elements([.template(GlowTemplate(
        .path([9]),
        element: .parameter(GlowParameter(.number(0), contents: GlowParameterContents(
          type: .octets,
          streamIdentifier: 5,
          streamDescriptor: GlowStreamDescription(format: .ieeeFloat32LittleEndian, offset: 4)
        ))),
        description: "level"
      ))]),
      .elements([.parameter(GlowParameter(.number(1), contents: GlowParameterContents(
        value: .octets([0, 1, 0xFF]),
        default: .null,
        templateReference: [9]
      )))]),
      .elements([]),
    ]
    for root in roots {
      XCTAssertEqual(try GlowRoot(decoding: root.encoded()), root)
    }
  }
}
