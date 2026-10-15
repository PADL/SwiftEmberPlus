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

import SwiftASN1

/// The APPLICATION tags of the Glow DTD.
enum GlowTag {
  static let root: UInt = 0
  static let parameter: UInt = 1
  static let command: UInt = 2
  static let node: UInt = 3
  static let elementCollection: UInt = 4
  static let streamEntry: UInt = 5
  static let streamCollection: UInt = 6
  static let stringIntegerPair: UInt = 7
  static let stringIntegerCollection: UInt = 8
  static let qualifiedParameter: UInt = 9
  static let qualifiedNode: UInt = 10
  static let rootElementCollection: UInt = 11
  static let streamDescription: UInt = 12
  static let matrix: UInt = 13
  static let target: UInt = 14
  static let source: UInt = 15
  static let connection: UInt = 16
  static let qualifiedMatrix: UInt = 17
  static let label: UInt = 18
  static let function: UInt = 19
  static let qualifiedFunction: UInt = 20
  static let tupleItemDescription: UInt = 21
  static let invocation: UInt = 22
  static let invocationResult: UInt = 23
  static let template: UInt = 24
  static let qualifiedTemplate: UInt = 25
}

// MARK: - Encoding

extension GlowRoot {
  /// The BER encoding of the message, with definite lengths throughout.
  public func encoded() -> [UInt8] {
    var serializer = DER.Serializer()
    serializer.appendApplication(GlowTag.root) { root in
      switch self {
      case let .elements(elements):
        root.appendApplication(GlowTag.rootElementCollection) { collection in
          for element in elements {
            collection.appendContext(0) { element.encode(into: &$0) }
          }
        }
      case let .streams(entries):
        root.appendApplication(GlowTag.streamCollection) { collection in
          for entry in entries {
            collection.appendContext(0) { $0.append(entry) }
          }
        }
      case let .invocationResult(result):
        root.append(result)
      }
    }
    return serializer.serializedBytes
  }
}

extension GlowElement {
  func encode(into serializer: inout DER.Serializer) {
    switch self {
    case let .parameter(parameter):
      serializer.appendElement(
        parameter.address,
        numbered: GlowTag.parameter,
        qualified: GlowTag.qualifiedParameter
      ) {
        if let contents = parameter.contents { $0.appendContext(1) { $0.append(contents) } }
        $0.appendChildren(parameter.children)
      }
    case let .node(node):
      serializer.appendElement(
        node.address,
        numbered: GlowTag.node,
        qualified: GlowTag.qualifiedNode
      ) {
        if let contents = node.contents { $0.appendContext(1) { $0.append(contents) } }
        $0.appendChildren(node.children)
      }
    case let .command(command):
      serializer.append(command)
    case let .matrix(matrix):
      serializer.appendElement(
        matrix.address,
        numbered: GlowTag.matrix,
        qualified: GlowTag.qualifiedMatrix
      ) { serializer in
        if let contents = matrix.contents {
          serializer.appendContext(1) { $0.append(contents) }
        }
        serializer.appendChildren(matrix.children)
        for (number, signals, tag) in [
          (UInt(3), matrix.targets, GlowTag.target),
          (UInt(4), matrix.sources, GlowTag.source),
        ] {
          guard let signals else { continue }
          serializer.appendContext(number) {
            $0.appendSequence { sequence in
              for signal in signals {
                sequence.appendContext(0) {
                  $0.appendApplication(tag) { $0.appendField(0, integer: signal) }
                }
              }
            }
          }
        }
        if let connections = matrix.connections {
          serializer.appendContext(5) {
            $0.appendSequence { sequence in
              for connection in connections {
                sequence.appendContext(0) { $0.append(connection) }
              }
            }
          }
        }
      }
    case let .function(function):
      serializer.appendElement(
        function.address,
        numbered: GlowTag.function,
        qualified: GlowTag.qualifiedFunction
      ) {
        if let contents = function.contents { $0.appendContext(1) { $0.append(contents) } }
        $0.appendChildren(function.children)
      }
    case let .template(template):
      // a template is a SET whose fields are numbered differently from other elements
      serializer.appendElement(
        template.address,
        numbered: GlowTag.template,
        qualified: GlowTag.qualifiedTemplate
      ) {
        if let element = template.element { $0.appendContext(1) { element.encode(into: &$0) } }
        $0.appendField(2, string: template.description)
      }
    }
  }
}

extension DER.Serializer {
  fileprivate mutating func appendElement(
    _ address: GlowAddress,
    numbered: UInt,
    qualified: UInt,
    _ fields: (inout DER.Serializer) -> ()
  ) {
    switch address {
    case let .number(number):
      appendApplication(numbered) {
        $0.appendField(0, integer: number)
        fields(&$0)
      }
    case let .path(path):
      appendApplication(qualified) {
        $0.appendField(0, relativeOID: path)
        fields(&$0)
      }
    }
  }

  fileprivate mutating func appendChildren(_ children: [GlowElement]?) {
    guard let children else { return }
    appendContext(2) {
      $0.appendApplication(GlowTag.elementCollection) { collection in
        for child in children {
          collection.appendContext(0) { child.encode(into: &$0) }
        }
      }
    }
  }

  fileprivate mutating func append(_ value: GlowValue) {
    switch value {
    case let .integer(value): appendInteger(value)
    case let .real(value): appendReal(value)
    case let .string(value): appendUTF8String(value)
    case let .boolean(value): appendBoolean(value)
    case let .octets(value): appendOctetString(value)
    case .null: appendNull()
    }
  }

  fileprivate mutating func append(_ value: GlowMinMax) {
    switch value {
    case let .integer(value): appendInteger(value)
    case let .real(value): appendReal(value)
    case .null: appendNull()
    }
  }

  fileprivate mutating func appendField(_ number: UInt, value: GlowValue?) {
    guard let value else { return }
    appendContext(number) { $0.append(value) }
  }

  fileprivate mutating func appendField(_ number: UInt, minMax: GlowMinMax?) {
    guard let minMax else { return }
    appendContext(number) { $0.append(minMax) }
  }

  fileprivate mutating func appendField(_ number: UInt, named value: (some GlowNamedInteger)?) {
    appendField(number, integer: value?.rawValue)
  }

  fileprivate mutating func appendTuple(_ values: [GlowValue]) {
    appendSequence { sequence in
      for value in values {
        sequence.appendContext(0) { $0.append(value) }
      }
    }
  }

  fileprivate mutating func appendTupleDescription(_ items: [GlowTupleItemDescription]) {
    appendSequence { sequence in
      for item in items {
        sequence.appendContext(0) {
          $0.appendApplication(GlowTag.tupleItemDescription) {
            $0.appendField(0, named: item.type)
            $0.appendField(1, string: item.name)
          }
        }
      }
    }
  }

  fileprivate mutating func append(_ contents: GlowNodeContents) {
    appendSet {
      $0.appendField(0, string: contents.identifier)
      $0.appendField(1, string: contents.description)
      $0.appendField(2, boolean: contents.isRoot)
      $0.appendField(3, boolean: contents.isOnline)
      $0.appendField(4, string: contents.schemaIdentifiers)
      $0.appendField(5, relativeOID: contents.templateReference)
    }
  }

  fileprivate mutating func append(_ contents: GlowParameterContents) {
    appendSet { set in
      set.appendField(0, string: contents.identifier)
      set.appendField(1, string: contents.description)
      set.appendField(2, value: contents.value)
      set.appendField(3, minMax: contents.minimum)
      set.appendField(4, minMax: contents.maximum)
      set.appendField(5, named: contents.access)
      set.appendField(6, string: contents.format)
      set.appendField(7, string: contents.enumeration)
      set.appendField(8, integer: contents.factor)
      set.appendField(9, boolean: contents.isOnline)
      set.appendField(10, string: contents.formula)
      set.appendField(11, integer: contents.step)
      set.appendField(12, value: contents.default)
      set.appendField(13, named: contents.type)
      set.appendField(14, integer: contents.streamIdentifier)
      if let enumMap = contents.enumMap {
        set.appendContext(15) {
          $0.appendApplication(GlowTag.stringIntegerCollection) { collection in
            for pair in enumMap {
              collection.appendContext(0) {
                $0.appendApplication(GlowTag.stringIntegerPair) {
                  $0.appendField(0, string: pair.string)
                  $0.appendField(1, integer: pair.integer)
                }
              }
            }
          }
        }
      }
      if let descriptor = contents.streamDescriptor {
        set.appendContext(16) {
          $0.appendApplication(GlowTag.streamDescription) {
            $0.appendField(0, named: descriptor.format)
            $0.appendField(1, integer: descriptor.offset)
          }
        }
      }
      set.appendField(17, string: contents.schemaIdentifiers)
      set.appendField(18, relativeOID: contents.templateReference)
    }
  }

  fileprivate mutating func append(_ contents: GlowFunctionContents) {
    appendSet { set in
      set.appendField(0, string: contents.identifier)
      set.appendField(1, string: contents.description)
      if let arguments = contents.arguments {
        set.appendContext(2) { $0.appendTupleDescription(arguments) }
      }
      if let result = contents.result {
        set.appendContext(3) { $0.appendTupleDescription(result) }
      }
      set.appendField(4, relativeOID: contents.templateReference)
    }
  }

  fileprivate mutating func append(_ contents: GlowMatrixContents) {
    appendSet { set in
      set.appendField(0, string: contents.identifier)
      set.appendField(1, string: contents.description)
      set.appendField(2, named: contents.type)
      set.appendField(3, named: contents.addressingMode)
      set.appendField(4, integer: contents.targetCount)
      set.appendField(5, integer: contents.sourceCount)
      set.appendField(6, integer: contents.maximumTotalConnects)
      set.appendField(7, integer: contents.maximumConnectsPerTarget)
      switch contents.parametersLocation {
      case let .basePath(path): set.appendContext(8) { $0.appendRelativeOID(path) }
      case let .inline(number): set.appendContext(8) { $0.appendInteger(number) }
      case nil: break
      }
      set.appendField(9, integer: contents.gainParameterNumber)
      if let labels = contents.labels {
        set.appendContext(10) {
          $0.appendSequence { sequence in
            for label in labels {
              sequence.appendContext(0) {
                $0.appendApplication(GlowTag.label) {
                  $0.appendField(0, relativeOID: label.basePath)
                  $0.appendField(1, string: label.description)
                }
              }
            }
          }
        }
      }
      set.appendField(11, string: contents.schemaIdentifiers)
      set.appendField(12, relativeOID: contents.templateReference)
    }
  }

  fileprivate mutating func append(_ connection: GlowConnection) {
    appendApplication(GlowTag.connection) {
      $0.appendField(0, integer: connection.target)
      $0.appendField(1, relativeOID: connection.sources)
      $0.appendField(2, named: connection.operation)
      $0.appendField(3, named: connection.disposition)
    }
  }

  fileprivate mutating func append(_ command: GlowCommand) {
    appendApplication(GlowTag.command) {
      $0.appendField(0, named: command.number)
      if let mask = command.dirFieldMask {
        $0.appendField(1, named: mask)
      } else if let invocation = command.invocation {
        $0.appendContext(2) { $0.append(invocation) }
      }
    }
  }

  fileprivate mutating func append(_ invocation: GlowInvocation) {
    appendApplication(GlowTag.invocation) {
      $0.appendField(0, integer: invocation.invocationID)
      if let arguments = invocation.arguments {
        $0.appendContext(1) { $0.appendTuple(arguments) }
      }
    }
  }

  fileprivate mutating func append(_ result: GlowInvocationResult) {
    appendApplication(GlowTag.invocationResult) {
      $0.appendField(0, integer: result.invocationID)
      $0.appendField(1, boolean: result.success)
      if let values = result.result {
        $0.appendContext(2) { $0.appendTuple(values) }
      }
    }
  }

  fileprivate mutating func append(_ entry: GlowStreamEntry) {
    appendApplication(GlowTag.streamEntry) {
      $0.appendField(0, integer: entry.streamIdentifier)
      $0.appendField(1, value: entry.value)
    }
  }
}

// MARK: - Decoding

extension GlowRoot {
  /// Decodes a message, which may use indefinite lengths. Elements of types this side does
  /// not know are dropped, as are fields with unknown tags.
  public init(decoding bytes: some Collection<UInt8>) throws {
    let root = try BER.parse(Array(bytes))
    try root.expect(.application(GlowTag.root))
    let choice = try root.explicitContent()
    switch choice.identifier {
    case .application(GlowTag.rootElementCollection):
      self = try .elements(choice.children().compactMap { node in
        try node.expect(.context(0))
        return try GlowElement(decoding: node.explicitContent())
      })
    case .application(GlowTag.streamCollection):
      self = try .streams(choice.children().map { node in
        try node.expect(.context(0))
        return try GlowStreamEntry(decoding: node.explicitContent())
      })
    case .application(GlowTag.invocationResult):
      self = try .invocationResult(GlowInvocationResult(decoding: choice))
    default:
      throw GlowDecodingError.unexpectedTag("root: \(choice.identifier)")
    }
  }
}

extension GlowElement {
  /// nil for an element of an unknown type.
  init?(decoding node: ASN1Node) throws {
    guard node.identifier.tagClass == .application else {
      throw GlowDecodingError.unexpectedTag("element: \(node.identifier)")
    }
    switch node.identifier.tagNumber {
    case GlowTag.parameter, GlowTag.qualifiedParameter:
      var parameter = GlowParameter(.number(0))
      try node.decodeElement(address: &parameter.address) { number, field in
        switch number {
        case 1: parameter.contents = try GlowParameterContents(decoding: field.explicitContent())
        case 2: parameter.children = try field.decodeChildren()
        default: break
        }
      }
      self = .parameter(parameter)
    case GlowTag.node, GlowTag.qualifiedNode:
      var element = GlowNode(.number(0))
      try node.decodeElement(address: &element.address) { number, field in
        switch number {
        case 1: element.contents = try GlowNodeContents(decoding: field.explicitContent())
        case 2: element.children = try field.decodeChildren()
        default: break
        }
      }
      self = .node(element)
    case GlowTag.command:
      self = try .command(GlowCommand(decoding: node))
    case GlowTag.matrix, GlowTag.qualifiedMatrix:
      var matrix = GlowMatrix(.number(0))
      try node.decodeElement(address: &matrix.address) { number, field in
        switch number {
        case 1: matrix.contents = try GlowMatrixContents(decoding: field.explicitContent())
        case 2: matrix.children = try field.decodeChildren()
        case 3: matrix.targets = try field.decodeSignals(GlowTag.target)
        case 4: matrix.sources = try field.decodeSignals(GlowTag.source)
        case 5:
          matrix.connections = try field.explicitContent().children().map {
            try GlowConnection(decoding: $0.explicitContent())
          }
        default: break
        }
      }
      self = .matrix(matrix)
    case GlowTag.function, GlowTag.qualifiedFunction:
      var function = GlowFunction(.number(0))
      try node.decodeElement(address: &function.address) { number, field in
        switch number {
        case 1: function.contents = try GlowFunctionContents(decoding: field.explicitContent())
        case 2: function.children = try field.decodeChildren()
        default: break
        }
      }
      self = .function(function)
    case GlowTag.template, GlowTag.qualifiedTemplate:
      var template = GlowTemplate(.number(0))
      try node.decodeElement(address: &template.address) { number, field in
        switch number {
        case 1: template.element = try GlowElement(decoding: field.explicitContent())
        case 2: template.description = try field.utf8String()
        default: break
        }
      }
      self = .template(template)
    default:
      return nil
    }
  }
}

extension ASN1Node {
  /// Decodes the number or path in field 0 and hands every other field to `field`.
  fileprivate func decodeElement(
    address: inout GlowAddress,
    _ field: (UInt, ASN1Node) throws -> ()
  ) throws {
    var found = false
    try forEachField { number, node in
      if number == 0 {
        let inner = try node.explicitContent()
        address = inner.is(.relativeOID) ?
          try .path(EmberBER.decodeRelativeOID(inner.contentBytes())) :
          try .number(node.integer32())
        found = true
      } else {
        try field(number, node)
      }
    }
    guard found else { throw GlowDecodingError.missingField("number or path") }
  }

  fileprivate func decodeChildren() throws -> [GlowElement] {
    let collection = try explicitContent()
    try collection.expect(.application(GlowTag.elementCollection))
    return try collection.children().compactMap {
      try GlowElement(decoding: $0.explicitContent())
    }
  }

  fileprivate func decodeSignals(_ tag: UInt) throws -> [Int32] {
    try explicitContent().children().map { wrapper in
      let signal = try wrapper.explicitContent()
      try signal.expect(.application(tag))
      var number: Int32?
      try signal.forEachField { if $0 == 0 { number = try $1.integer32() } }
      guard let number else { throw GlowDecodingError.missingField("signal number") }
      return number
    }
  }

  fileprivate func named<T: GlowNamedInteger>(_: T.Type = T.self) throws -> T {
    try T(rawValue: integer32())!
  }

  fileprivate func value() throws -> GlowValue {
    try GlowValue(decoding: explicitContent())
  }

  fileprivate func minMax() throws -> GlowMinMax {
    switch try GlowValue(decoding: explicitContent()) {
    case let .integer(value): .integer(value)
    case let .real(value): .real(value)
    case .null: .null
    default: throw GlowDecodingError.invalidValue("minimum or maximum")
    }
  }

  fileprivate func tuple() throws -> [GlowValue] {
    try explicitContent().children().map { try $0.value() }
  }

  fileprivate func tupleDescription() throws -> [GlowTupleItemDescription] {
    try explicitContent().children().map { wrapper in
      let item = try wrapper.explicitContent()
      try item.expect(.application(GlowTag.tupleItemDescription))
      var description = GlowTupleItemDescription(type: .null)
      try item.forEachField { number, field in
        switch number {
        case 0: description.type = try field.named()
        case 1: description.name = try field.utf8String()
        default: break
        }
      }
      return description
    }
  }
}

extension GlowValue {
  init(decoding node: ASN1Node) throws {
    let bytes = try node.contentBytes()
    switch node.identifier {
    case .integer: self = try .integer(EmberBER.decodeInteger(bytes))
    case .real: self = try .real(EmberBER.decodeReal(bytes))
    case .utf8String: self = try .string(EmberBER.decodeUTF8(bytes))
    case .boolean: self = try .boolean(EmberBER.decodeBoolean(bytes))
    case .octetString: self = .octets(bytes)
    case .null: self = .null
    default: throw GlowDecodingError.unexpectedTag("value: \(node.identifier)")
    }
  }
}

extension GlowNodeContents {
  init(decoding node: ASN1Node) throws {
    self.init()
    try node.forEachField { number, field in
      switch number {
      case 0: identifier = try field.utf8String()
      case 1: description = try field.utf8String()
      case 2: isRoot = try field.boolean()
      case 3: isOnline = try field.boolean()
      case 4: schemaIdentifiers = try field.utf8String()
      case 5: templateReference = try field.relativeOID()
      default: break
      }
    }
  }
}

extension GlowParameterContents {
  init(decoding node: ASN1Node) throws {
    self.init()
    try node.forEachField { number, field in
      switch number {
      case 0: identifier = try field.utf8String()
      case 1: description = try field.utf8String()
      case 2: value = try field.value()
      case 3: minimum = try field.minMax()
      case 4: maximum = try field.minMax()
      case 5: access = try field.named()
      case 6: format = try field.utf8String()
      case 7: enumeration = try field.utf8String()
      case 8: factor = try field.integer32()
      case 9: isOnline = try field.boolean()
      case 10: formula = try field.utf8String()
      case 11: step = try field.integer32()
      case 12: self.default = try field.value()
      case 13: type = try field.named()
      case 14: streamIdentifier = try field.integer32()
      case 15:
        let collection = try field.explicitContent()
        try collection.expect(.application(GlowTag.stringIntegerCollection))
        enumMap = try collection.children().map { wrapper in
          let pair = try wrapper.explicitContent()
          try pair.expect(.application(GlowTag.stringIntegerPair))
          var string: String?
          var integer: Int32?
          try pair.forEachField { number, field in
            switch number {
            case 0: string = try field.utf8String()
            case 1: integer = try field.integer32()
            default: break
            }
          }
          guard let string, let integer else {
            throw GlowDecodingError.missingField("enumeration entry")
          }
          return GlowStringIntegerPair(string, integer)
        }
      case 16:
        let description = try field.explicitContent()
        try description.expect(.application(GlowTag.streamDescription))
        var format: GlowStreamFormat?
        var offset: Int32?
        try description.forEachField { number, field in
          switch number {
          case 0: format = try field.named()
          case 1: offset = try field.integer32()
          default: break
          }
        }
        guard let format, let offset else {
          throw GlowDecodingError.missingField("stream descriptor")
        }
        streamDescriptor = GlowStreamDescription(format: format, offset: offset)
      case 17: schemaIdentifiers = try field.utf8String()
      case 18: templateReference = try field.relativeOID()
      default: break
      }
    }
  }
}

extension GlowFunctionContents {
  init(decoding node: ASN1Node) throws {
    self.init()
    try node.forEachField { number, field in
      switch number {
      case 0: identifier = try field.utf8String()
      case 1: description = try field.utf8String()
      case 2: arguments = try field.tupleDescription()
      case 3: result = try field.tupleDescription()
      case 4: templateReference = try field.relativeOID()
      default: break
      }
    }
  }
}

extension GlowMatrixContents {
  init(decoding node: ASN1Node) throws {
    self.init(identifier: "", targetCount: 0, sourceCount: 0)
    try node.forEachField { number, field in
      switch number {
      case 0: identifier = try field.utf8String()
      case 1: description = try field.utf8String()
      case 2: type = try field.named()
      case 3: addressingMode = try field.named()
      case 4: targetCount = try field.integer32()
      case 5: sourceCount = try field.integer32()
      case 6: maximumTotalConnects = try field.integer32()
      case 7: maximumConnectsPerTarget = try field.integer32()
      case 8:
        let inner = try field.explicitContent()
        parametersLocation = inner.is(.relativeOID) ?
          try .basePath(EmberBER.decodeRelativeOID(inner.contentBytes())) :
          try .inline(field.integer32())
      case 9: gainParameterNumber = try field.integer32()
      case 10:
        labels = try field.explicitContent().children().map { wrapper in
          let label = try wrapper.explicitContent()
          try label.expect(.application(GlowTag.label))
          var basePath: GlowPath?
          var description: String?
          try label.forEachField { number, field in
            switch number {
            case 0: basePath = try field.relativeOID()
            case 1: description = try field.utf8String()
            default: break
            }
          }
          guard let basePath, let description else {
            throw GlowDecodingError.missingField("label")
          }
          return GlowLabel(basePath: basePath, description: description)
        }
      case 11: schemaIdentifiers = try field.utf8String()
      case 12: templateReference = try field.relativeOID()
      default: break
      }
    }
  }
}

extension GlowConnection {
  init(decoding node: ASN1Node) throws {
    try node.expect(.application(GlowTag.connection))
    var target: Int32?
    self.init(target: 0)
    try node.forEachField { number, field in
      switch number {
      case 0: target = try field.integer32()
      case 1: sources = try field.relativeOID()
      case 2: operation = try field.named()
      case 3: disposition = try field.named()
      default: break
      }
    }
    guard let target else { throw GlowDecodingError.missingField("connection target") }
    self.target = target
  }
}

extension GlowCommand {
  init(decoding node: ASN1Node) throws {
    try node.expect(.application(GlowTag.command))
    var number: GlowCommandType?
    self.init(.getDirectory)
    try node.forEachField { tag, field in
      switch tag {
      case 0: number = try field.named()
      case 1: dirFieldMask = try field.named()
      case 2: invocation = try GlowInvocation(decoding: field.explicitContent())
      default: break
      }
    }
    guard let number else { throw GlowDecodingError.missingField("command number") }
    self.number = number
  }
}

extension GlowInvocation {
  init(decoding node: ASN1Node) throws {
    try node.expect(.application(GlowTag.invocation))
    self.init()
    try node.forEachField { number, field in
      switch number {
      case 0: invocationID = try field.integer32()
      case 1: arguments = try field.tuple()
      default: break
      }
    }
  }
}

extension GlowInvocationResult {
  init(decoding node: ASN1Node) throws {
    try node.expect(.application(GlowTag.invocationResult))
    var invocationID: Int32?
    self.init(invocationID: 0)
    try node.forEachField { number, field in
      switch number {
      case 0: invocationID = try field.integer32()
      case 1: success = try field.boolean()
      case 2: result = try field.tuple()
      default: break
      }
    }
    guard let invocationID else { throw GlowDecodingError.missingField("invocation id") }
    self.invocationID = invocationID
  }
}

extension GlowStreamEntry {
  init(decoding node: ASN1Node) throws {
    try node.expect(.application(GlowTag.streamEntry))
    var streamIdentifier: Int32?
    var value: GlowValue?
    try node.forEachField { number, field in
      switch number {
      case 0: streamIdentifier = try field.integer32()
      case 1: value = try field.value()
      default: break
      }
    }
    guard let streamIdentifier, let value else {
      throw GlowDecodingError.missingField("stream entry")
    }
    self.init(streamIdentifier: streamIdentifier, value: value)
  }
}
