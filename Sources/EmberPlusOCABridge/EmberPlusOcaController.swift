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
import Synchronization

/// The controller an Ember+ session is to the device. It speaks OCP.2, so values arrive
/// as JSON-like values, and is named for the session's peer, which is what the device's
/// logs and locks know it by.
actor EmberPlusOcaController: OcaController, CustomStringConvertible {
  typealias Changed = @Sendable (OcaONo, OcaPropertyID) async -> ()

  nonisolated let flags: OcaControllerFlags = .supportsLocking
  nonisolated let description: String
  nonisolated var controlProtocol: OcaControlProtocol { .ocp2 }
  private let changed: Changed

  init(description: String, changed: @escaping Changed) {
    self.description = description
    self.changed = changed
  }

  init(session: EmberPlusSession, changed: @escaping Changed) {
    self.init(description: "ember/tcp/\(session.peerDescription)", changed: changed)
  }

  /// The only messages a device sends a controller unasked are notifications. Which
  /// object and property one is about is all that is taken from it: the value is read
  /// afresh, as the session's own GetDirectory would read it.
  func sendMessages(_ messages: [any Ocp1Message], type messageType: OcaMessageType) async throws {
    guard messageType == .ocaNtf2 else { return }
    for case let notification as Ocp1Notification2 in messages
      where notification.event.eventID == OcaPropertyChangedEventID
    {
      let property = try OcaEventDataCoding.propertyID(from: notification.eventData)
      await changed(notification.event.emitterONo, property)
    }
  }
}

/// Where the device finds the controllers of the open Ember+ sessions, to notify them.
final class EmberPlusOcaEndpoint: OcaDeviceEndpoint {
  private let sessions = Mutex([EmberPlusOcaController]())

  func add(_ controller: EmberPlusOcaController) {
    sessions.withLock { $0.append(controller) }
  }

  func remove(_ controller: EmberPlusOcaController) {
    sessions.withLock { $0.removeAll { $0 === controller } }
  }

  var controllers: [any OcaController] {
    get async { sessions.withLock { $0 } }
  }
}
