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

// The Glow DTD 2.50 (Ember+ Documentation, "Glow DTD ASN.1 Notation"). Optional properties
// are those the DTD makes OPTIONAL; a nil collection is absent, where an empty one is
// present and empty, which Ember+ distinguishes (a node queried for children it does not
// have answers with no contents at all).

public typealias GlowPath = [UInt32]

public enum GlowValue: Sendable, Hashable {
  case integer(Int64)
  case real(Double)
  case string(String)
  case boolean(Bool)
  case octets([UInt8])
  case null
}

public enum GlowMinMax: Sendable, Hashable {
  case integer(Int64)
  case real(Double)
  case null
}

/// An INTEGER with named values, which a peer may extend with values this side does not
/// know.
public protocol GlowNamedInteger: RawRepresentable, Sendable, Hashable
  where RawValue == Int32 {}

public struct GlowParameterType: GlowNamedInteger, CustomStringConvertible {
  public let rawValue: Int32
  public init(rawValue: Int32) { self.rawValue = rawValue }

  public static let null = Self(rawValue: 0)
  public static let integer = Self(rawValue: 1)
  public static let real = Self(rawValue: 2)
  public static let string = Self(rawValue: 3)
  public static let boolean = Self(rawValue: 4)
  public static let trigger = Self(rawValue: 5)
  public static let `enum` = Self(rawValue: 6)
  public static let octets = Self(rawValue: 7)

  private static let names = [
    "null", "integer", "real", "string", "boolean", "trigger", "enum", "octets",
  ]

  public var description: String {
    Self.names.indices.contains(Int(rawValue)) ? Self.names[Int(rawValue)] : "\(rawValue)"
  }
}

public struct GlowParameterAccess: GlowNamedInteger {
  public let rawValue: Int32
  public init(rawValue: Int32) { self.rawValue = rawValue }

  public static let none = Self(rawValue: 0)
  public static let read = Self(rawValue: 1)
  public static let write = Self(rawValue: 2)
  public static let readWrite = Self(rawValue: 3)
}

public struct GlowCommandType: GlowNamedInteger {
  public let rawValue: Int32
  public init(rawValue: Int32) { self.rawValue = rawValue }

  public static let subscribe = Self(rawValue: 30)
  public static let unsubscribe = Self(rawValue: 31)
  public static let getDirectory = Self(rawValue: 32)
  public static let invoke = Self(rawValue: 33)
}

public struct GlowFieldFlags: GlowNamedInteger {
  public let rawValue: Int32
  public init(rawValue: Int32) { self.rawValue = rawValue }

  public static let sparse = Self(rawValue: -2)
  public static let all = Self(rawValue: -1)
  public static let `default` = Self(rawValue: 0)
  public static let identifier = Self(rawValue: 1)
  public static let description = Self(rawValue: 2)
  public static let tree = Self(rawValue: 3)
  public static let value = Self(rawValue: 4)
  public static let connections = Self(rawValue: 5)
}

public struct GlowStreamFormat: GlowNamedInteger {
  public let rawValue: Int32
  public init(rawValue: Int32) { self.rawValue = rawValue }

  public static let unsignedInt8 = Self(rawValue: 0)
  public static let unsignedInt16BigEndian = Self(rawValue: 2)
  public static let unsignedInt16LittleEndian = Self(rawValue: 3)
  public static let unsignedInt32BigEndian = Self(rawValue: 4)
  public static let unsignedInt32LittleEndian = Self(rawValue: 5)
  public static let unsignedInt64BigEndian = Self(rawValue: 6)
  public static let unsignedInt64LittleEndian = Self(rawValue: 7)
  public static let signedInt8 = Self(rawValue: 8)
  public static let signedInt16BigEndian = Self(rawValue: 10)
  public static let signedInt16LittleEndian = Self(rawValue: 11)
  public static let signedInt32BigEndian = Self(rawValue: 12)
  public static let signedInt32LittleEndian = Self(rawValue: 13)
  public static let signedInt64BigEndian = Self(rawValue: 14)
  public static let signedInt64LittleEndian = Self(rawValue: 15)
  public static let ieeeFloat32BigEndian = Self(rawValue: 20)
  public static let ieeeFloat32LittleEndian = Self(rawValue: 21)
  public static let ieeeFloat64BigEndian = Self(rawValue: 22)
  public static let ieeeFloat64LittleEndian = Self(rawValue: 23)
}

public struct GlowMatrixType: GlowNamedInteger {
  public let rawValue: Int32
  public init(rawValue: Int32) { self.rawValue = rawValue }

  public static let oneToN = Self(rawValue: 0)
  public static let oneToOne = Self(rawValue: 1)
  public static let nToN = Self(rawValue: 2)
}

public struct GlowMatrixAddressingMode: GlowNamedInteger {
  public let rawValue: Int32
  public init(rawValue: Int32) { self.rawValue = rawValue }

  public static let linear = Self(rawValue: 0)
  public static let nonLinear = Self(rawValue: 1)
}

public struct GlowConnectionOperation: GlowNamedInteger {
  public let rawValue: Int32
  public init(rawValue: Int32) { self.rawValue = rawValue }

  public static let absolute = Self(rawValue: 0)
  public static let connect = Self(rawValue: 1)
  public static let disconnect = Self(rawValue: 2)
}

public struct GlowConnectionDisposition: GlowNamedInteger {
  public let rawValue: Int32
  public init(rawValue: Int32) { self.rawValue = rawValue }

  public static let tally = Self(rawValue: 0)
  public static let modified = Self(rawValue: 1)
  public static let pending = Self(rawValue: 2)
  public static let locked = Self(rawValue: 3)
}

public struct GlowStringIntegerPair: Sendable, Hashable {
  public var string: String
  public var integer: Int32

  public init(_ string: String, _ integer: Int32) {
    self.string = string
    self.integer = integer
  }
}

public struct GlowStreamDescription: Sendable, Hashable {
  public var format: GlowStreamFormat
  /// The byte offset of the value within the streamed octets.
  public var offset: Int32

  public init(format: GlowStreamFormat, offset: Int32) {
    self.format = format
    self.offset = offset
  }
}

public struct GlowTupleItemDescription: Sendable, Hashable {
  public var type: GlowParameterType
  public var name: String?

  public init(type: GlowParameterType, name: String? = nil) {
    self.type = type
    self.name = name
  }
}

/// How an element is identified: by number within its parent, or by its full path from the
/// root, which makes it a qualified element that can appear at the top of a message.
public enum GlowAddress: Sendable, Hashable {
  case number(Int32)
  case path(GlowPath)
}

public struct GlowNodeContents: Sendable, Hashable {
  public var identifier: String?
  public var description: String?
  public var isRoot: Bool?
  public var isOnline: Bool?
  public var schemaIdentifiers: String?
  public var templateReference: GlowPath?

  public init(
    identifier: String? = nil,
    description: String? = nil,
    isRoot: Bool? = nil,
    isOnline: Bool? = nil,
    schemaIdentifiers: String? = nil,
    templateReference: GlowPath? = nil
  ) {
    self.identifier = identifier
    self.description = description
    self.isRoot = isRoot
    self.isOnline = isOnline
    self.schemaIdentifiers = schemaIdentifiers
    self.templateReference = templateReference
  }
}

public struct GlowParameterContents: Sendable, Hashable {
  public var identifier: String?
  public var description: String?
  public var value: GlowValue?
  public var minimum: GlowMinMax?
  public var maximum: GlowMinMax?
  public var access: GlowParameterAccess?
  public var format: String?
  public var enumeration: String?
  public var factor: Int32?
  public var isOnline: Bool?
  public var formula: String?
  public var step: Int32?
  public var `default`: GlowValue?
  public var type: GlowParameterType?
  public var streamIdentifier: Int32?
  public var enumMap: [GlowStringIntegerPair]?
  public var streamDescriptor: GlowStreamDescription?
  public var schemaIdentifiers: String?
  public var templateReference: GlowPath?

  public init(
    identifier: String? = nil,
    description: String? = nil,
    value: GlowValue? = nil,
    minimum: GlowMinMax? = nil,
    maximum: GlowMinMax? = nil,
    access: GlowParameterAccess? = nil,
    format: String? = nil,
    enumeration: String? = nil,
    factor: Int32? = nil,
    isOnline: Bool? = nil,
    formula: String? = nil,
    step: Int32? = nil,
    default: GlowValue? = nil,
    type: GlowParameterType? = nil,
    streamIdentifier: Int32? = nil,
    enumMap: [GlowStringIntegerPair]? = nil,
    streamDescriptor: GlowStreamDescription? = nil,
    schemaIdentifiers: String? = nil,
    templateReference: GlowPath? = nil
  ) {
    self.identifier = identifier
    self.description = description
    self.value = value
    self.minimum = minimum
    self.maximum = maximum
    self.access = access
    self.format = format
    self.enumeration = enumeration
    self.factor = factor
    self.isOnline = isOnline
    self.formula = formula
    self.step = step
    self.default = `default`
    self.type = type
    self.streamIdentifier = streamIdentifier
    self.enumMap = enumMap
    self.streamDescriptor = streamDescriptor
    self.schemaIdentifiers = schemaIdentifiers
    self.templateReference = templateReference
  }
}

public struct GlowFunctionContents: Sendable, Hashable {
  public var identifier: String?
  public var description: String?
  public var arguments: [GlowTupleItemDescription]?
  public var result: [GlowTupleItemDescription]?
  public var templateReference: GlowPath?

  public init(
    identifier: String? = nil,
    description: String? = nil,
    arguments: [GlowTupleItemDescription]? = nil,
    result: [GlowTupleItemDescription]? = nil,
    templateReference: GlowPath? = nil
  ) {
    self.identifier = identifier
    self.description = description
    self.arguments = arguments
    self.result = result
    self.templateReference = templateReference
  }
}

public enum GlowParametersLocation: Sendable, Hashable {
  case basePath(GlowPath)
  case inline(Int32)
}

public struct GlowLabel: Sendable, Hashable {
  public var basePath: GlowPath
  public var description: String

  public init(basePath: GlowPath, description: String) {
    self.basePath = basePath
    self.description = description
  }
}

public struct GlowMatrixContents: Sendable, Hashable {
  public var identifier: String
  public var description: String?
  public var type: GlowMatrixType?
  public var addressingMode: GlowMatrixAddressingMode?
  public var targetCount: Int32
  public var sourceCount: Int32
  public var maximumTotalConnects: Int32?
  public var maximumConnectsPerTarget: Int32?
  public var parametersLocation: GlowParametersLocation?
  public var gainParameterNumber: Int32?
  public var labels: [GlowLabel]?
  public var schemaIdentifiers: String?
  public var templateReference: GlowPath?

  public init(
    identifier: String,
    description: String? = nil,
    type: GlowMatrixType? = nil,
    addressingMode: GlowMatrixAddressingMode? = nil,
    targetCount: Int32,
    sourceCount: Int32,
    maximumTotalConnects: Int32? = nil,
    maximumConnectsPerTarget: Int32? = nil,
    parametersLocation: GlowParametersLocation? = nil,
    gainParameterNumber: Int32? = nil,
    labels: [GlowLabel]? = nil,
    schemaIdentifiers: String? = nil,
    templateReference: GlowPath? = nil
  ) {
    self.identifier = identifier
    self.description = description
    self.type = type
    self.addressingMode = addressingMode
    self.targetCount = targetCount
    self.sourceCount = sourceCount
    self.maximumTotalConnects = maximumTotalConnects
    self.maximumConnectsPerTarget = maximumConnectsPerTarget
    self.parametersLocation = parametersLocation
    self.gainParameterNumber = gainParameterNumber
    self.labels = labels
    self.schemaIdentifiers = schemaIdentifiers
    self.templateReference = templateReference
  }
}

public struct GlowConnection: Sendable, Hashable {
  public var target: Int32
  /// Absent or empty means no sources.
  public var sources: [UInt32]?
  public var operation: GlowConnectionOperation?
  public var disposition: GlowConnectionDisposition?

  public init(
    target: Int32,
    sources: [UInt32]? = nil,
    operation: GlowConnectionOperation? = nil,
    disposition: GlowConnectionDisposition? = nil
  ) {
    self.target = target
    self.sources = sources
    self.operation = operation
    self.disposition = disposition
  }
}

public struct GlowInvocation: Sendable, Hashable {
  public var invocationID: Int32?
  public var arguments: [GlowValue]?

  public init(invocationID: Int32? = nil, arguments: [GlowValue]? = nil) {
    self.invocationID = invocationID
    self.arguments = arguments
  }
}

public struct GlowInvocationResult: Sendable, Hashable {
  public var invocationID: Int32
  public var success: Bool?
  public var result: [GlowValue]?

  public init(invocationID: Int32, success: Bool? = nil, result: [GlowValue]? = nil) {
    self.invocationID = invocationID
    self.success = success
    self.result = result
  }
}

public struct GlowStreamEntry: Sendable, Hashable {
  public var streamIdentifier: Int32
  public var value: GlowValue

  public init(streamIdentifier: Int32, value: GlowValue) {
    self.streamIdentifier = streamIdentifier
    self.value = value
  }
}

public struct GlowCommand: Sendable, Hashable {
  public var number: GlowCommandType
  /// Only with `getDirectory`.
  public var dirFieldMask: GlowFieldFlags?
  /// Only with `invoke`.
  public var invocation: GlowInvocation?

  public init(
    _ number: GlowCommandType,
    dirFieldMask: GlowFieldFlags? = nil,
    invocation: GlowInvocation? = nil
  ) {
    self.number = number
    self.dirFieldMask = dirFieldMask
    self.invocation = invocation
  }
}

public struct GlowNode: Sendable, Hashable {
  public var address: GlowAddress
  public var contents: GlowNodeContents?
  public var children: [GlowElement]?

  public init(
    _ address: GlowAddress,
    contents: GlowNodeContents? = nil,
    children: [GlowElement]? = nil
  ) {
    self.address = address
    self.contents = contents
    self.children = children
  }
}

public struct GlowParameter: Sendable, Hashable {
  public var address: GlowAddress
  public var contents: GlowParameterContents?
  public var children: [GlowElement]?

  public init(
    _ address: GlowAddress,
    contents: GlowParameterContents? = nil,
    children: [GlowElement]? = nil
  ) {
    self.address = address
    self.contents = contents
    self.children = children
  }
}

public struct GlowFunction: Sendable, Hashable {
  public var address: GlowAddress
  public var contents: GlowFunctionContents?
  public var children: [GlowElement]?

  public init(
    _ address: GlowAddress,
    contents: GlowFunctionContents? = nil,
    children: [GlowElement]? = nil
  ) {
    self.address = address
    self.contents = contents
    self.children = children
  }
}

public struct GlowMatrix: Sendable, Hashable {
  public var address: GlowAddress
  public var contents: GlowMatrixContents?
  public var children: [GlowElement]?
  public var targets: [Int32]?
  public var sources: [Int32]?
  public var connections: [GlowConnection]?

  public init(
    _ address: GlowAddress,
    contents: GlowMatrixContents? = nil,
    children: [GlowElement]? = nil,
    targets: [Int32]? = nil,
    sources: [Int32]? = nil,
    connections: [GlowConnection]? = nil
  ) {
    self.address = address
    self.contents = contents
    self.children = children
    self.targets = targets
    self.sources = sources
    self.connections = connections
  }
}

public struct GlowTemplate: Sendable, Hashable {
  public var address: GlowAddress
  /// A parameter, node, matrix or function.
  public var element: GlowElement?
  public var description: String?

  public init(_ address: GlowAddress, element: GlowElement? = nil, description: String? = nil) {
    self.address = address
    self.element = element
    self.description = description
  }
}

public indirect enum GlowElement: Sendable, Hashable {
  case parameter(GlowParameter)
  case node(GlowNode)
  case command(GlowCommand)
  case matrix(GlowMatrix)
  case function(GlowFunction)
  case template(GlowTemplate)

  public var address: GlowAddress? {
    switch self {
    case let .parameter(parameter): parameter.address
    case let .node(node): node.address
    case .command: nil
    case let .matrix(matrix): matrix.address
    case let .function(function): function.address
    case let .template(template): template.address
    }
  }

  public var children: [GlowElement]? {
    switch self {
    case let .parameter(parameter): parameter.children
    case let .node(node): node.children
    case .command: nil
    case let .matrix(matrix): matrix.children
    case let .function(function): function.children
    case .template: nil
    }
  }
}

/// A whole Glow message.
public enum GlowRoot: Sendable, Hashable {
  /// Elements, nested by number or qualified by path.
  case elements([GlowElement])
  case streams([GlowStreamEntry])
  case invocationResult(GlowInvocationResult)
}
