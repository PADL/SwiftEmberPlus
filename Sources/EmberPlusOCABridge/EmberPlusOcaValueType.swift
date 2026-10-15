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

import EmberPlus
import Foundation
@_spi(SwiftOCAPrivate)
import SwiftOCA

/// How a value of an AES70 type is presented as an Ember+ parameter value. A type with no
/// Ember+ counterpart (a structure, list or map) is shown as its OCP.2 JSON, read only.
indirect enum EmberPlusOcaValueType: Sendable {
  case boolean
  case integer
  case real
  case string
  case enumeration([(name: String, value: Int64)])
  case optional(EmberPlusOcaValueType)
  case json

  init(_ type: Any.Type) {
    switch OcaDatatypeKind(of: type) {
    case let .base(base):
      switch base {
      case .ocaBoolean: self = .boolean
      case .ocaInt8, .ocaInt16, .ocaInt32, .ocaInt64,
           .ocaUint8, .ocaUint16, .ocaUint32, .ocaUint64: self = .integer
      case .ocaFloat32, .ocaFloat64: self = .real
      case .ocaString: self = .string
      default: self = .json
      }
    case let .enumeration(cases): self = .enumeration(cases)
    case let .rawValue(raw), let .bounded(raw): self = .init(raw)
    case let .optional(wrapped): self = .optional(.init(wrapped))
    default: self = .json
    }
  }

  var parameterType: GlowParameterType {
    switch self {
    case .boolean: .boolean
    case .integer: .integer
    case .real: .real
    case .string, .json: .string
    case .enumeration: .enum
    case let .optional(wrapped): wrapped.parameterType
    }
  }

  /// Whether it is one of Ember+'s own types, rather than JSON, which is for reading only.
  var isScalar: Bool {
    switch self {
    case .json: false
    case let .optional(wrapped): wrapped.isScalar
    default: true
    }
  }

  /// Whether it is an integer or a real, as a stream's value is.
  var isNumeric: Bool {
    switch self {
    case .integer, .real: true
    default: false
    }
  }

  var enumeration: [(name: String, value: Int64)]? {
    switch self {
    case let .enumeration(cases): cases
    case let .optional(wrapped): wrapped.enumeration
    default: nil
    }
  }

  /// The Ember+ value of an OCP.2 value, nil if it is not of this type.
  func glowValue(ocp2 value: Any) -> GlowValue? {
    switch self {
    case .boolean:
      return (value as? Bool).map(GlowValue.boolean)
    case .integer, .enumeration:
      return Self.integer(value).map(GlowValue.integer)
    case .real:
      return Self.real(value).map(GlowValue.real)
    case .string:
      return (value as? String).map(GlowValue.string)
    case let .optional(wrapped):
      return value is NSNull ? .null : wrapped.glowValue(ocp2: value)
    case .json:
      guard let data = try? JSONSerialization.data(
        withJSONObject: value,
        options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
      ) else { return nil }
      return .string(String(decoding: data, as: UTF8.self))
    }
  }

  /// The OCP.2 value of an Ember+ value, for a setter or method to decode; nil if the
  /// value cannot be one of this type.
  func ocp2Value(_ value: GlowValue) -> Any? {
    switch (self, value) {
    case let (.boolean, .boolean(value)): value
    case let (.boolean, .integer(value)): value != 0
    case let (.integer, .integer(value)), let (.enumeration, .integer(value)): Int(value)
    case let (.integer, .real(value)), let (.enumeration, .real(value)):
      Int64(exactly: value).map { Int($0) }
    case let (.real, .real(value)): Self.ocp2Real(value)
    case let (.real, .integer(value)): Double(value)
    case let (.string, .string(value)): value
    case (.optional, .null): NSNull()
    case let (.optional(wrapped), value): wrapped.ocp2Value(value)
    default: nil
    }
  }

  /// The range of an OCP.2 bound, nil where it is infinite and so no bound.
  func glowMinMax(ocp2 value: Any) -> GlowMinMax? {
    switch self {
    case .integer, .enumeration: Self.integer(value).map(GlowMinMax.integer)
    case .real: Self.real(value).flatMap { $0.isFinite ? .real($0) : nil }
    case let .optional(wrapped): wrapped.glowMinMax(ocp2: value)
    default: nil
    }
  }

  private static func integer(_ value: Any) -> Int64? {
    switch value {
    case is Bool: nil
    case let value as Int: Int64(value)
    case let value as Int64: value
    // an unsigned value beyond Int64 is shown as the largest Ember+ can carry
    case let value as UInt64: Int64(exactly: value) ?? .max
    case let value as Double: Int64(exactly: value)
    default: nil
    }
  }

  /// OCP.2 writes the floats JSON has no number for as text.
  private static func real(_ value: Any) -> Double? {
    switch value {
    case is Bool: nil
    case let value as Double: value
    case let value as Float: Double(value)
    case let value as Int: Double(value)
    case let value as Int64: Double(value)
    case let value as String:
      switch value {
      case "Infinity", "+Infinity": .infinity
      case "-Infinity": -.infinity
      case "NaN": .nan
      default: nil
      }
    default: nil
    }
  }

  private static func ocp2Real(_ value: Double) -> Any {
    if value.isNaN { return "NaN" }
    if value.isInfinite { return value > 0 ? "Infinity" : "-Infinity" }
    return value
  }
}

/// A display format for the AES70 types that carry a unit.
func emberPlusFormat(typeName: String?) -> String? {
  switch typeName {
  case "OcaDB", "OcaDBFS", "OcaDBu", "OcaDBV", "OcaDBz": "%.2f°dB"
  case "OcaFrequency": "%.1f°Hz"
  case "OcaTimeInterval": "%.3f°s"
  case "OcaPeriod": "%d°ms"
  case "OcaTemperature": "%.1f°°C"
  case "OcaVoltage": "%.2f°V"
  case "OcaCurrent": "%.3f°A"
  default: nil
  }
}
