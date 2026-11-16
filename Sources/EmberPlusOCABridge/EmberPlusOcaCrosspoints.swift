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

/// An OCA matrix of boolean actuators is a crosspoint matrix: the actuator at (x, y)
/// connects source y to target x when it is set. OCA's matrices are grids of objects of
/// any kind, and only this kind is a router; any other presents no matrix.
///
/// The matrix's own node is the matrix: nToN, linear, unlabelled. Each crosspoint is read
/// and written through its actuator's own accessors, as the session's controller.
extension SwiftOCADevice.OcaMatrix: EmberPlusOcaMatrixRepresentable {
  /// The OCA property a crosspoint's state is: OcaBooleanActuator's Setting.
  static var crosspointSetting: OcaPropertyID {
    OcaPropertyID("5.1")
  }

  private var crosspointSize: (targets: Int, sources: Int)? {
    let (x, y) = (members.nX, members.nY)
    var count = 0
    for target in 0..<x {
      for source in 0..<y {
        guard let member = members[target, source] else { continue }
        guard member is SwiftOCADevice.OcaBooleanActuator else { return nil }
        count += 1
      }
    }
    guard count > 0, x <= Int(Int32.max), y <= Int(Int32.max) else { return nil }
    return (x, y)
  }

  public var emberPlusMatrices: [EmberPlusOcaMatrix] {
    guard crosspointSize != nil else { return [] }
    return [EmberPlusOcaMatrix(number: nil, type: .nToN, addressingMode: .linear)]
  }

  public func emberPlusEmitters(for matrix: EmberPlusOcaMatrix) -> [OcaONo] {
    var emitters = [OcaONo]()
    for target in 0..<members.nX {
      for source in 0..<members.nY {
        if let member = members[target, source] { emitters.append(member.objectNumber) }
      }
    }
    return emitters
  }

  public var emberPlusConnectionProperties: Set<OcaPropertyID> {
    [Self.crosspointSetting]
  }

  public func emberPlusSignals(for matrix: EmberPlusOcaMatrix) -> EmberPlusOcaSignals {
    let (targets, sources) = crosspointSize ?? (0, 0)
    return EmberPlusOcaSignals(
      targets: (0..<targets).map { EmberPlusOcaSignal(Int32($0)) },
      sources: (0..<sources).map { EmberPlusOcaSignal(Int32($0)) }
    )
  }

  public func emberPlusConnections(
    for matrix: EmberPlusOcaMatrix,
    controller: any OcaController
  ) async -> [Int32: [Int32]] {
    guard let (targets, _) = crosspointSize else { return [:] }
    var connections = [Int32: [Int32]]()
    for target in 0..<targets {
      connections[Int32(target)] = await sources(of: target, as: controller)
    }
    return connections
  }

  /// Sets each crosspoint that is to change. If any write is refused, the request is,
  /// with the other writes standing.
  public func emberPlusConnect(
    _ changes: [EmberPlusOcaConnectionChange],
    matrix: EmberPlusOcaMatrix,
    controller: any OcaController
  ) async throws -> [Int32: [Int32]] {
    var refusal: OcaStatus?
    var connections = [Int32: [Int32]]()
    for change in changes {
      let target = Int(change.target)
      let wanted = await Set(change.applied(to: sources(of: target, as: controller)))
      for source in 0..<members.nY {
        guard let crosspoint = members[target, source] else { continue }
        let connect = wanted.contains(Int32(source))
        guard await isConnected(crosspoint, as: controller) != connect else { continue }
        let status = await setCrosspoint(crosspoint, connect, as: controller)
        if status != .ok { refusal = status }
      }
      connections[change.target] = await sources(of: target, as: controller)
    }
    if let refusal { throw Ocp1Error.status(refusal) }
    return connections
  }

  private func sources(of target: Int, as controller: any OcaController) async -> [Int32] {
    var sources = [Int32]()
    for source in 0..<members.nY {
      if let crosspoint = members[target, source], await isConnected(crosspoint, as: controller) {
        sources.append(Int32(source))
      }
    }
    return sources
  }

  private func settingDescriptor(_ crosspoint: SwiftOCADevice
    .OcaRoot) -> OcaDevicePropertyDescriptor?
  {
    crosspoint.deviceClassDescriptors.lazy.flatMap(\.properties)
      .first { $0.propertyID == Self.crosspointSetting }
  }

  /// The crosspoint's state, as its setting reads to the controller.
  private func isConnected(
    _ crosspoint: SwiftOCADevice.OcaRoot,
    as controller: any OcaController
  ) async -> Bool {
    guard let device = deviceDelegate, let descriptor = settingDescriptor(crosspoint),
          let getter = descriptor.getMethodID else { return false }
    let (status, answer) = await device.send(getter, to: crosspoint.objectNumber, from: controller)
    guard status == .ok, let answer else { return false }
    let value = descriptor.ocp2GetNames.first.flatMap { answer[$0] }
      ?? (answer.count == 1 ? answer.values.first : nil)
    return value as? Bool == true
  }

  private func setCrosspoint(
    _ crosspoint: SwiftOCADevice.OcaRoot,
    _ connect: Bool,
    as controller: any OcaController
  ) async -> OcaStatus {
    guard let device = deviceDelegate, let descriptor = settingDescriptor(crosspoint),
          let setter = descriptor.setMethodID else { return .permissionDenied }
    let parameters: [String: Any] = [descriptor.ocp2SetName: connect]
    return await device.send(
      setter,
      to: crosspoint.objectNumber,
      ocp2Parameters: parameters,
      from: controller
    )
    .status
  }
}
