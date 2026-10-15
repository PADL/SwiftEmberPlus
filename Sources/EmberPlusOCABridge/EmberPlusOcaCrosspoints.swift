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

@_spi(SwiftOCAPrivate)
import SwiftOCA
@_spi(SwiftOCAPrivate)
import SwiftOCADevice

/// An OCA matrix, whatever its members' class.
@OcaDevice
protocol EmberPlusOcaMatrixRepresentable: SwiftOCADevice.OcaRoot {
  var matrixSize: (x: Int, y: Int) { get }
  func matrixMember(x: Int, y: Int) -> SwiftOCADevice.OcaRoot?
}

extension SwiftOCADevice.OcaMatrix: EmberPlusOcaMatrixRepresentable {
  var matrixSize: (x: Int, y: Int) { (members.nX, members.nY) }

  func matrixMember(x: Int, y: Int) -> SwiftOCADevice.OcaRoot? {
    members[x, y]
  }
}

/// An OCA matrix of boolean actuators, which Ember+ presents as a crosspoint matrix: the
/// actuator at (x, y) connects source y to target x when it is set. OCA's matrices are
/// grids of objects of any kind, and only this kind is a router.
@OcaDevice
struct EmberPlusOcaCrosspoints {
  let matrix: any EmberPlusOcaMatrixRepresentable
  let targetCount: Int
  let sourceCount: Int

  /// The OCA property a crosspoint's state is: OcaBooleanActuator's Setting.
  static let setting = OcaPropertyID("5.1")

  init?(_ object: SwiftOCADevice.OcaRoot) {
    guard let matrix = object as? any EmberPlusOcaMatrixRepresentable else { return nil }
    let (x, y) = matrix.matrixSize
    var members = 0
    for target in 0..<x {
      for source in 0..<y {
        guard let member = matrix.matrixMember(x: target, y: source) else { continue }
        guard member is SwiftOCADevice.OcaBooleanActuator else { return nil }
        members += 1
      }
    }
    guard members > 0, x <= Int(Int32.max), y <= Int(Int32.max) else { return nil }
    self.matrix = matrix
    targetCount = x
    sourceCount = y
  }

  func crosspoint(target: Int, source: Int) -> SwiftOCADevice.OcaRoot? {
    guard (0..<targetCount).contains(target), (0..<sourceCount).contains(source) else {
      return nil
    }
    return matrix.matrixMember(x: target, y: source)
  }

  /// Each crosspoint's target, by its actuator's object number.
  var targets: [OcaONo: Int] {
    var targets = [OcaONo: Int]()
    for target in 0..<targetCount {
      for source in 0..<sourceCount {
        if let member = matrix.matrixMember(x: target, y: source) {
          targets[member.objectNumber] = target
        }
      }
    }
    return targets
  }
}
