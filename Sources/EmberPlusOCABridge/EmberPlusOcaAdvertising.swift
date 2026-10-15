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

#if canImport(dnssd)
import EmberPlus
@_spi(SwiftOCAPrivate)
import SwiftOCA
@_spi(SwiftOCAPrivate)
import SwiftOCADevice

extension EmberPlusProvider where Source == EmberPlusOcaTreeSource {
  /// The DNS-SD service type of an Ember+ provider (Ember+ Service Discovery).
  public static var serviceType: String { "_ember._tcp" }

  /// Advertises the provider over DNS-SD until cancelled, named for the device as its
  /// device manager names it (or for the host, until it has a name), as SwiftOCA
  /// advertises a device's OCA endpoints.
  @OcaDevice
  public func advertise(device: OcaDevice = .shared) async throws {
    guard let deviceManager = await device.deviceManager else { return }
    var registration: DNSServiceRegistration?
    do {
      for try await deviceName in deviceManager.$deviceName {
        try Task.checkCancellation()
        await registration?.deregister()
        registration = try? await DNSServiceRegistration(
          name: deviceName.isEmpty ? nil : deviceName,
          regType: Self.serviceType,
          port: port
        )
      }
    } catch {
      // deregistered now, so the goodbye is sent before the process can exit
      await registration?.deregister()
      throw error
    }
    await registration?.deregister()
  }
}
#endif
