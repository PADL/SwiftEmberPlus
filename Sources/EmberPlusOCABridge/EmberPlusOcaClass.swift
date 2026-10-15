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
import Logging
@_spi(SwiftOCAPrivate)
import SwiftOCA
@_spi(SwiftOCAPrivate)
import SwiftOCADevice

/// How an object's node numbers its children. AES70 reserves object numbers below 4096
/// for standard objects, so that range carries the properties and methods of the object
/// (by definition level and index) and the managers under the root block, while the
/// members of a block are numbered by their object numbers, which stay the same for as
/// long as they exist.
///
/// Ember+ numbers are 32-bit signed integers (EmberLib.net holds a path's arcs as such),
/// and some devices use the top bits of an object number to classify objects (Inferno's
/// are `0xMXXO_IIAA`, with the top bit for a master channel's objects), so a member's
/// number is the first of these that is in the member range and not a sibling's: its
/// object number without the top bit, or `0x7000_0000` with the object number's low 24
/// bits. A number need only be unique among its siblings, as a path is resolved through
/// each block's members.
enum EmberPlusOcaNumbering {
  static let firstMemberNumber = UInt32(OcaMaximumReservedONo) + 1

  /// 0x100 to 0x7FF.
  static func number(of property: OcaPropertyID) -> UInt32? {
    guard (1...7).contains(property.defLevel), (1...255).contains(property.propertyIndex) else {
      return nil
    }
    return UInt32(property.defLevel) << 8 | UInt32(property.propertyIndex)
  }

  /// 0x900 to 0xFFF.
  static func number(of method: OcaMethodID) -> UInt32? {
    guard (1...7).contains(method.defLevel), (1...255).contains(method.methodIndex) else {
      return nil
    }
    return 0x800 | UInt32(method.defLevel) << 8 | UInt32(method.methodIndex)
  }

  /// A manager is numbered by its object number under the root block.
  static func isManager(_ number: UInt32) -> Bool { number < 0x100 }
  static func isMember(_ number: UInt32) -> Bool { number >= firstMemberNumber }

  /// The numbers a member of a block may have, in order of preference.
  static func candidates(forMember objectNumber: OcaONo) -> [UInt32] {
    let objectNumber = UInt32(objectNumber)
    return [objectNumber & 0x7FFF_FFFF, 0x7000_0000 | objectNumber & 0x00FF_FFFF]
      .filter(isMember)
  }
}

/// One Ember+ parameter: an OCA property, one component of a vector property, or a
/// property AES70 defines that a class serves only through its accessor methods (as
/// OcaRoot's Role is served by GetRole).
struct EmberPlusOcaParameter: Sendable {
  enum Accessors: Sendable {
    /// A declared property; for a vector's component, its field in the pair the
    /// accessors read and write.
    case property(OcaDevicePropertyDescriptor, component: String?)
    /// A getter that takes nothing and answers with the value, or the value and its
    /// bounds, and maybe a setter that takes the value alone.
    case methods(
      get: OcaMethodID,
      result: String,
      bounds: (minimum: String, maximum: String)?,
      set: (OcaMethodID, parameter: String)?
    )
  }

  let number: UInt32
  let identifier: String
  /// The property its change events carry, where it is known: a vector's component has
  /// its own.
  let propertyID: OcaPropertyID?
  let accessors: Accessors
  let type: EmberPlusOcaValueType
  let typeName: String?
  /// A sensor's numeric reading, which changes often: Ember+ has a consumer subscribe to
  /// it, and sends its changes in a stream collection.
  var isStream = false

  var getMethodID: OcaMethodID? {
    switch accessors {
    case let .property(descriptor, _): descriptor.getMethodID
    case let .methods(get, _, _, _): get
    }
  }

  var isWritable: Bool {
    guard type.isScalar else { return false }
    switch accessors {
    case let .property(descriptor, _): return descriptor.isSettable
    case let .methods(_, _, _, set): return set != nil
    }
  }

  var isBounded: Bool {
    switch accessors {
    case let .property(descriptor, nil): descriptor.flags.contains(.bounded)
    case .property: false
    case let .methods(_, _, bounds, _): bounds != nil
    }
  }
}

/// One Ember+ function of an OCA method that is not a property accessor, and whose
/// arguments and results are all of types Ember+ has.
struct EmberPlusOcaFunction: Sendable {
  let number: UInt32
  let identifier: String
  let methodID: OcaMethodID
  let parameters: [(name: String, type: EmberPlusOcaValueType)]
  let results: [(name: String, type: EmberPlusOcaValueType)]
}

/// What a class presents: worked out from its device property and method descriptors
/// once for each Swift class.
///
/// Ember+ reads and writes values as parameters, so a property's accessors are not
/// presented as functions (as IS-12 serves them by its own Get and Set). Neither is a
/// method that is a property's accessor in all but declaration: a getter that takes
/// nothing and returns one value (or, for a bounded value, the value and its bounds, as
/// `X`, `MinX` and `MaxX`) is a read-only parameter, writable if the class has the
/// matching setter. Its number is the AES70 property's where that is known, so that its
/// change events find it, and otherwise the getter's.
struct EmberPlusOcaClass: Sendable {
  /// The AES70 properties that classes serve by accessors alone, by the getter's name and
  /// definition level.
  private static let accessorProperties: [String: OcaPropertyID] = [
    "1:GetClassIdentification": OcaPropertyID("1.1"),
    "1:GetLockable": OcaPropertyID("1.4"),
    "1:GetRole": OcaPropertyID("1.5"),
    "1:GetLockState": OcaPropertyID("1.6"),
    // OcaLevelSensor's Reading, which it keeps outside a device property for speed
    "4:GetReading": OcaPropertyID("4.1"),
  ]

  /// OcaRoot's lock methods (LockTotal, Unlock and LockReadonly), which are not
  /// presented: a lock is a controller's, and an Ember+ consumer has no way to hold one
  /// that makes sense to it.
  private static let lockMethods: Set<OcaMethodID> = [
    OcaMethodID("1.3"), OcaMethodID("1.4"), OcaMethodID("1.6"),
  ]

  let parameters: [EmberPlusOcaParameter]
  let functions: [EmberPlusOcaFunction]
  private let parametersByNumber: [UInt32: Int]
  private let functionsByNumber: [UInt32: Int]

  func parameter(_ number: UInt32) -> EmberPlusOcaParameter? {
    parametersByNumber[number].map { parameters[$0] }
  }

  func function(_ number: UInt32) -> EmberPlusOcaFunction? {
    functionsByNumber[number].map { functions[$0] }
  }

  func parameters(for property: OcaPropertyID) -> [EmberPlusOcaParameter] {
    parameters.filter { $0.propertyID == property }
  }

  /// Properties of structured types (records, lists and maps) are presented as JSON
  /// strings only if `presentsStructuredValues`.
  @OcaDevice
  init(of object: SwiftOCADevice.OcaRoot, presentsStructuredValues: Bool, logger: Logger) {
    var parameters = [EmberPlusOcaParameter]()
    var functions = [EmberPlusOcaFunction]()
    let levels = object.deviceClassDescriptors
    let accessors = Set(levels.flatMap(\.properties).flatMap { [$0.getMethodID, $0.setMethodID] }
      .compactMap(\.self))

    for level in levels {
      for property in level.visibleProperties where property.getMethodID != nil {
        parameters += Self.parameters(of: property, logger: logger)
      }

      // a subclass that declares a method again is the one it is dispatched to
      let methods = Dictionary(level.visibleMethods.map { ($0.methodID, $0) }, uniquingKeysWith: { $1 })
        .values.filter { !accessors.contains($0.methodID) && $0.isDescribed }
        .sorted { $0.methodID.methodIndex < $1.methodID.methodIndex }
      let byName = Dictionary(methods.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
      var setters = Set<OcaMethodID>()

      var getters = Set<OcaMethodID>()
      for method in methods {
        guard let (stem, result, bounds) = Self.getter(method) else { continue }
        getters.insert(method.methodID)
        let type = EmberPlusOcaValueType(result.type)
        // a setter of the same stem that takes one value of the getter's type
        var set: (OcaMethodID, parameter: String)?
        if let setter = byName["Set" + stem], setter.parameters.count == 1, setter.results.isEmpty,
           ObjectIdentifier(setter.parameters[0].type) == ObjectIdentifier(result.type)
        {
          set = (setter.methodID, setter.parameters[0].name)
          setters.insert(setter.methodID)
        }
        let propertyID = Self.accessorProperties["\(method.methodID.defLevel):\(method.name)"]
        guard let number = propertyID.flatMap(EmberPlusOcaNumbering.number(of:))
          ?? EmberPlusOcaNumbering.number(of: method.methodID) else { continue }
        parameters.append(EmberPlusOcaParameter(
          number: number,
          identifier: stem.prefix(1).lowercased() + stem.dropFirst(),
          propertyID: propertyID,
          accessors: .methods(get: method.methodID, result: result.name, bounds: bounds, set: set),
          type: type,
          typeName: result.typeName
        ))
      }

      for method in methods where !getters.contains(method.methodID) && !setters.contains(method.methodID)
        && !Self.lockMethods.contains(method.methodID)
      {
        guard let number = EmberPlusOcaNumbering.number(of: method.methodID) else { continue }
        let parameterTypes = method.parameters.map { ($0.name, EmberPlusOcaValueType($0.type)) }
        let resultTypes = method.results.map { ($0.name, EmberPlusOcaValueType($0.type)) }
        // a function's tuple is of scalar types only
        guard (parameterTypes + resultTypes).allSatisfy({ $0.1.isScalar }) else {
          logger.trace("not presenting \(method.name): it takes or returns a structure")
          continue
        }
        functions.append(EmberPlusOcaFunction(
          number: number, identifier: method.name, methodID: method.methodID,
          parameters: parameterTypes, results: resultTypes
        ))
      }
    }

    if !presentsStructuredValues {
      parameters.removeAll { !$0.type.isScalar }
    }
    // a sensor's reading is the first property its own class defines, below OcaSensor
    if object is SwiftOCADevice.OcaSensor {
      for index in parameters.indices {
        let parameter = parameters[index]
        guard let property = parameter.propertyID, property.defLevel >= 4,
              property.propertyIndex == 1, parameter.type.isNumeric else { continue }
        parameters[index].isStream = true
      }
    }
    self.parameters = parameters
    self.functions = functions
    parametersByNumber = Dictionary(
      parameters.enumerated().map { ($1.number, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    functionsByNumber = Dictionary(
      functions.enumerated().map { ($1.number, $0) },
      uniquingKeysWith: { first, _ in first }
    )
  }

  /// A getter's stem, the result that is its value, and the results that are its bounds.
  private static func getter(_ method: OcaDeviceMethodDescriptor)
    -> (String, OcaParameterDescriptor, (minimum: String, maximum: String)?)?
  {
    guard method.name.hasPrefix("Get"), method.parameters.isEmpty else { return nil }
    let stem = String(method.name.dropFirst(3))
    switch method.results.count {
    case 1:
      return (stem, method.results[0], nil)
    case 3 where method.results[1].name == "Min" + method.results[0].name
      && method.results[2].name == "Max" + method.results[0].name:
      return (stem, method.results[0], (method.results[1].name, method.results[2].name))
    default:
      return nil
    }
  }

  private static func parameters(
    of property: OcaDevicePropertyDescriptor,
    logger: Logger
  ) -> [EmberPlusOcaParameter] {
    if let yPropertyID = property.yPropertyID, let componentType = property.componentType,
       let names = property.componentNames
    {
      // a vector is two OCA properties with one pair of accessors
      return [(names.x, property.propertyID, "X"), (names.y, yPropertyID, "Y")]
        .compactMap { name, id, field in
          EmberPlusOcaNumbering.number(of: id).map {
            EmberPlusOcaParameter(
              number: $0, identifier: name, propertyID: id,
              accessors: .property(property, component: field),
              type: EmberPlusOcaValueType(componentType), typeName: property.typeName
            )
          }
        }
    }
    guard let number = EmberPlusOcaNumbering.number(of: property.propertyID) else {
      logger.trace("not presenting \(property.name): \(property.propertyID) has no number")
      return []
    }
    return [EmberPlusOcaParameter(
      number: number, identifier: property.name, propertyID: property.propertyID,
      accessors: .property(property, component: nil),
      type: EmberPlusOcaValueType(property.valueType), typeName: property.typeName
    )]
  }
}
