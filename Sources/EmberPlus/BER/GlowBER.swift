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

import SwiftASN1

/// The universal types Glow uses that swift-asn1 does not name.
extension ASN1Identifier {
  static let real = ASN1Identifier(tagWithNumber: 9, tagClass: .universal)
  static let relativeOID = ASN1Identifier(tagWithNumber: 13, tagClass: .universal)

  static func context(_ number: UInt) -> ASN1Identifier {
    ASN1Identifier(tagWithNumber: number, tagClass: .contextSpecific)
  }

  static func application(_ number: UInt) -> ASN1Identifier {
    ASN1Identifier(tagWithNumber: number, tagClass: .application)
  }
}

public enum GlowDecodingError: Error, Sendable, Hashable {
  case unexpectedTag(String)
  case expectedConstructed
  case expectedPrimitive
  case missingField(String)
  case invalidValue(String)
}

// MARK: - Encoding

/// Glow is EXPLICIT TAGS throughout: every field is a constructed context tag around a
/// complete universal or application TLV.
extension DER.Serializer {
  mutating func appendContext(
    _ number: UInt,
    _ writer: (inout DER.Serializer) throws -> ()
  ) rethrows {
    try appendConstructedNode(identifier: .context(number), writer)
  }

  mutating func appendApplication(
    _ number: UInt,
    _ writer: (inout DER.Serializer) throws -> ()
  ) rethrows {
    try appendConstructedNode(identifier: .application(number), writer)
  }

  mutating func appendSequence(_ writer: (inout DER.Serializer) throws -> ()) rethrows {
    try appendConstructedNode(identifier: .sequence, writer)
  }

  mutating func appendSet(_ writer: (inout DER.Serializer) throws -> ()) rethrows {
    try appendConstructedNode(identifier: .set, writer)
  }

  mutating func appendPrimitive(_ identifier: ASN1Identifier, _ bytes: [UInt8]) {
    appendPrimitiveNode(identifier: identifier) { $0.append(contentsOf: bytes) }
  }

  mutating func appendInteger(_ value: Int64) {
    appendPrimitive(.integer, EmberBER.encodeInteger(value))
  }

  mutating func appendInteger(_ value: Int32) { appendInteger(Int64(value)) }

  mutating func appendBoolean(_ value: Bool) {
    appendPrimitive(.boolean, EmberBER.encodeBoolean(value))
  }

  mutating func appendReal(_ value: Double) {
    appendPrimitive(.real, EmberBER.encodeReal(value))
  }

  mutating func appendUTF8String(_ value: String) {
    appendPrimitive(.utf8String, Array(value.utf8))
  }

  mutating func appendOctetString(_ value: [UInt8]) {
    appendPrimitive(.octetString, value)
  }

  mutating func appendNull() {
    appendPrimitive(.null, [])
  }

  mutating func appendRelativeOID(_ arcs: [UInt32]) {
    appendPrimitive(.relativeOID, EmberBER.encodeRelativeOID(arcs))
  }

  // context-tagged fields, omitted when nil

  mutating func appendField(_ number: UInt, integer value: Int32?) {
    guard let value else { return }
    appendContext(number) { $0.appendInteger(value) }
  }

  mutating func appendField(_ number: UInt, boolean value: Bool?) {
    guard let value else { return }
    appendContext(number) { $0.appendBoolean(value) }
  }

  mutating func appendField(_ number: UInt, string value: String?) {
    guard let value else { return }
    appendContext(number) { $0.appendUTF8String(value) }
  }

  mutating func appendField(_ number: UInt, relativeOID value: [UInt32]?) {
    guard let value else { return }
    appendContext(number) { $0.appendRelativeOID(value) }
  }
}

// MARK: - Decoding

extension ASN1Node {
  var isConstructed: Bool {
    if case .constructed = content { return true }
    return false
  }

  func `is`(_ identifier: ASN1Identifier) -> Bool {
    self.identifier == identifier
  }

  func children() throws -> ASN1NodeCollection {
    guard case let .constructed(children) = content else {
      throw GlowDecodingError.expectedConstructed
    }
    return children
  }

  /// The single TLV inside an explicit tag.
  func explicitContent() throws -> ASN1Node {
    var iterator = try children().makeIterator()
    guard let inner = iterator.next() else {
      throw GlowDecodingError.missingField("\(identifier)")
    }
    return inner
  }

  /// A primitive's contents, joining the segments of a constructed string as BER allows.
  func contentBytes() throws -> [UInt8] {
    switch content {
    case let .primitive(bytes):
      return Array(bytes)
    case let .constructed(children):
      return try children.flatMap { try $0.contentBytes() }
    }
  }

  func expect(_ identifier: ASN1Identifier) throws {
    guard self.identifier == identifier else {
      throw GlowDecodingError.unexpectedTag("expected \(identifier), found \(self.identifier)")
    }
  }

  func integer64() throws -> Int64 {
    let node = try explicitContent()
    try node.expect(.integer)
    return try EmberBER.decodeInteger(node.contentBytes())
  }

  func integer32() throws -> Int32 {
    let node = try explicitContent()
    try node.expect(.integer)
    return try EmberBER.decodeInteger32(node.contentBytes())
  }

  func boolean() throws -> Bool {
    let node = try explicitContent()
    try node.expect(.boolean)
    return try EmberBER.decodeBoolean(node.contentBytes())
  }

  func utf8String() throws -> String {
    let node = try explicitContent()
    try node.expect(.utf8String)
    return try EmberBER.decodeUTF8(node.contentBytes())
  }

  func relativeOID() throws -> [UInt32] {
    let node = try explicitContent()
    try node.expect(.relativeOID)
    return try EmberBER.decodeRelativeOID(node.contentBytes())
  }

  /// Visits the context-tagged fields of a SET or SEQUENCE in whatever order they come,
  /// leaving tags the visitor does not know to be skipped for forward compatibility.
  func forEachField(_ body: (UInt, ASN1Node) throws -> ()) throws {
    for child in try children() where child.identifier.tagClass == .contextSpecific {
      try body(child.identifier.tagNumber, child)
    }
  }
}
