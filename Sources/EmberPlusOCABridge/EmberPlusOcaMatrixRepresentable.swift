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
@_spi(SwiftOCAPrivate)
import SwiftOCA
@_spi(SwiftOCAPrivate)
import SwiftOCADevice

/// One Ember+ crosspoint matrix an object presents.
public struct EmberPlusOcaMatrix: Sendable, Hashable {
  /// The matrix's number under the object's node, 1 to 255; nil when the object's own node
  /// is the matrix.
  public var number: UInt32?
  /// The matrix's identifier; nil for the object's own, as its parent presents it.
  public var identifier: String?
  public var description: String?
  public var type: GlowMatrixType
  public var addressingMode: GlowMatrixAddressingMode
  /// The description of the matrix's one label layer (Ember+ `Label.description`), or nil
  /// for a matrix without labels.
  public var labels: String?

  public init(
    number: UInt32?,
    identifier: String? = nil,
    description: String? = nil,
    type: GlowMatrixType,
    addressingMode: GlowMatrixAddressingMode,
    labels: String? = nil
  ) {
    self.number = number
    self.identifier = identifier
    self.description = description
    self.type = type
    self.addressingMode = addressingMode
    self.labels = labels
  }
}

/// A target or source of a matrix: its signal number, the index for a linear matrix, and
/// its label.
public struct EmberPlusOcaSignal: Sendable, Hashable {
  public var number: Int32
  public var label: String?

  public init(_ number: Int32, label: String? = nil) {
    self.number = number
    self.label = label
  }
}

/// A matrix's targets and sources, in the order they are presented.
public struct EmberPlusOcaSignals: Sendable, Hashable {
  public var targets: [EmberPlusOcaSignal]
  public var sources: [EmberPlusOcaSignal]

  public init(targets: [EmberPlusOcaSignal], sources: [EmberPlusOcaSignal]) {
    self.targets = targets
    self.sources = sources
  }
}

/// A consumer's request for one target: Ember+ `Connection` with its operation, the sources
/// known to the matrix only.
public struct EmberPlusOcaConnectionChange: Sendable, Hashable {
  public var target: Int32
  public var sources: [Int32]
  /// `absolute` makes the target's sources these; `connect` adds them; `disconnect` removes
  /// them.
  public var operation: GlowConnectionOperation

  public init(target: Int32, sources: [Int32], operation: GlowConnectionOperation = .absolute) {
    self.target = target
    self.sources = sources
    self.operation = operation
  }
}

/// An OCA object that presents Ember+ crosspoint matrices of its own. `EmberPlusOcaTreeSource`
/// presents each as a standard Glow matrix: its targets, sources and labels, one connection
/// per target, a consumer's connection requests applied through `emberPlusConnect`, and the
/// changes the object's property events announce.
///
/// An OCA matrix whose members are all boolean actuators conforms: see `OcaMatrix`.
@OcaDevice
public protocol EmberPlusOcaMatrixRepresentable: SwiftOCADevice.OcaRoot {
  /// The matrices, which a change of `emberPlusSignalProperties` may not add to or remove.
  var emberPlusMatrices: [EmberPlusOcaMatrix] { get }

  /// The objects whose property changes `emberPlusConnectionProperties` and
  /// `emberPlusSignalProperties` name; by default the object itself.
  func emberPlusEmitters(for matrix: EmberPlusOcaMatrix) -> [OcaONo]

  /// The properties whose change means a matrix's connections may have changed.
  var emberPlusConnectionProperties: Set<OcaPropertyID> { get }

  /// The properties whose change means a matrix's targets, sources or labels may have
  /// changed.
  var emberPlusSignalProperties: Set<OcaPropertyID> { get }

  /// The matrix's targets and sources as they are now.
  func emberPlusSignals(for matrix: EmberPlusOcaMatrix) -> EmberPlusOcaSignals

  /// Each target's sources as they are now, as `controller` may read them; a target
  /// missing has none.
  func emberPlusConnections(
    for matrix: EmberPlusOcaMatrix,
    controller: any OcaController
  ) async -> [Int32: [Int32]]

  /// Applies a consumer's request as `controller`'s write, so that its locks and access
  /// checks apply. Returns the sources of each target in `changes` after it, or throws
  /// (`Ocp1Error.status`) if it was refused, which leaves the connections as they were.
  func emberPlusConnect(
    _ changes: [EmberPlusOcaConnectionChange],
    matrix: EmberPlusOcaMatrix,
    controller: any OcaController
  ) async throws -> [Int32: [Int32]]
}

public extension EmberPlusOcaMatrixRepresentable {
  func emberPlusEmitters(for matrix: EmberPlusOcaMatrix) -> [OcaONo] {
    [objectNumber]
  }

  var emberPlusSignalProperties: Set<OcaPropertyID> {
    []
  }
}

public extension EmberPlusOcaConnectionChange {
  /// The target's sources after the change, from `current`.
  func applied(to current: [Int32]) -> [Int32] {
    switch operation {
    case .connect:
      current + sources.filter { !current.contains($0) }
    case .disconnect:
      current.filter { !sources.contains($0) }
    default:
      sources
    }
  }
}
