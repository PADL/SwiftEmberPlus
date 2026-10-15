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
import EmberPlusOCABridge
import Foundation
import Logging
import SwiftOCA
import SwiftOCADevice
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(IORing)
import IORing
#endif

/// SwiftOCA's OCADevice example, with an Ember+ provider in front of it: the same objects
/// (a block of boolean actuators in a matrix, a gain whose changes a counter notifier
/// counts), and a channel strip whose gain, mute and level meter exercise the bridge.
/// The device prints what Ember+ consumers change, as the OCA side sees it, and serves
/// OCP.1 and OCP.2 alongside, so a change can be made from either side and seen on the
/// other.
///
///     EmberPlusDevice [--port 9000] [--oca-port 65000] [--no-meter] [--debug]
///
/// OCP.1 is on the OCA port, OCP.2 (JSON) on the OCA port + 3, as OCADevice has them.
@main
enum EmberPlusDeviceApp {
  struct Options {
    var port = EmberPlusProvider<EmberPlusOcaTreeSource>.defaultPort
    var ocaPort: UInt16 = 65000
    var meter = true
    var debug = false
  }

  static func main() async throws {
    #if canImport(IORing)
    // as OCADevice: the executor's threads never exit, and every task runs there
    try IORing.installExecutor(policy: .global)
    #endif
    var options = Options()
    var arguments = CommandLine.arguments.dropFirst()
    while let argument = arguments.popFirst() {
      switch argument {
      case "--port": options.port = arguments.popFirst().flatMap(UInt16.init) ?? options.port
      case "--oca-port": options.ocaPort = arguments.popFirst().flatMap(UInt16.init) ?? options.ocaPort
      case "--no-meter": options.meter = false
      case "--debug": options.debug = true
      default:
        print("usage: EmberPlusDevice [--port 9000] [--oca-port 65000] [--no-meter] [--debug]")
        exit(1)
      }
    }
    LoggingSystem.bootstrap { label in
      var handler = StreamLogHandler.standardError(label: label)
      handler.logLevel = options.debug ? .debug : .info
      return handler
    }

    let objects = try await makeObjects()
    let ocp1Endpoint = try await OcaTCPDeviceEndpoint(address: anyAddress(port: options.ocaPort))
    let ocp2Endpoint = try await OcaTCPDeviceEndpoint(
      address: anyAddress(port: options.ocaPort + 3),
      controlProtocol: .ocp2
    )
    let provider = EmberPlusProvider(
      source: EmberPlusOcaTreeSource(rootIdentifier: "OCADevice"),
      port: options.port
    )

    report(objects)
    print("Ember+ provider on port \(options.port)")
    print("OCP.1 on port \(options.ocaPort), OCP.2 on port \(options.ocaPort + 3)")
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await provider.run() }
      #if canImport(dnssd)
      group.addTask { try await provider.advertise() }
      #endif
      group.addTask { try await ocp1Endpoint.run() }
      group.addTask { try await ocp2Endpoint.run() }
      if options.meter {
        group.addTask { try await animate(objects.level) }
      }
      try await group.next()
      group.cancelAll()
    }
  }

  struct Objects: Sendable {
    let gain: SwiftOCADevice.OcaGain
    let counterSetAgent: SwiftOCADevice.OcaCounterSetAgent
    let channelGain: SwiftOCADevice.OcaGain
    let mute: SwiftOCADevice.OcaMute
    let level: SwiftOCADevice.OcaLevelSensor
  }

  final class BooleanActuator: SwiftOCADevice.OcaBooleanActuator {
    override class var classID: OcaClassID { OcaClassID(parent: super.classID, 65280) }
  }

  @OcaDevice
  private static func makeObjects() async throws -> Objects {
    let device = OcaDevice.shared
    try await device.initializeDefaultObjects()
    let deviceManager = await device.deviceManager!
    deviceManager.deviceName = "Ember+ Test"
    deviceManager.serialNumber = "EmberPlusDevice-00000001"
    deviceManager.modelGUID = OcaModelGUID(mfrCode: .init((0, 0, 0)), modelCode: (1, 2, 3, 4))

    // as OCADevice: a block of actuators, which are also the members of a matrix
    let matrix = try await SwiftOCADevice.OcaMatrix<BooleanActuator>(
      rows: 4, columns: 2, objectNumber: 10001, deviceDelegate: device
    )
    let block = try await SwiftOCADevice.OcaBlock<SwiftOCADevice.OcaWorker>(
      objectNumber: 10000, role: "Block", deviceDelegate: device
    )
    var actuatorONo: OcaONo = 10010
    let members = matrix.members
    for x in 0..<members.nX {
      for y in 0..<members.nY {
        let actuator = try await BooleanActuator(
          objectNumber: actuatorONo, role: "Actuator(\(x),\(y))",
          deviceDelegate: device, addToRootBlock: false
        )
        actuatorONo += 1
        try await block.add(actionObject: actuator)
        try await matrix.add(
          member: actuator,
          at: OcaVector2D(x: OcaMatrixCoordinate(x), y: OcaMatrixCoordinate(y))
        )
      }
    }
    let gain = try await SwiftOCADevice.OcaGain(
      objectNumber: 10020, role: "Gain", deviceDelegate: device, addToRootBlock: false
    )
    try await block.add(actionObject: gain)

    // counts the gain's changes
    let counterNotifier = try await SwiftOCADevice.OcaCounterNotifier(
      objectNumber: 10030, role: "Gain Change Notifier", deviceDelegate: device
    )
    let counterSetAgent = try await SwiftOCADevice.OcaCounterSetAgent(
      objectNumber: 10031, role: "Gain Changes", deviceDelegate: device
    )
    counterNotifier.filterParameters = OcaCounterNotifierFilterParameters(
      threshold: 0, operator: .none, period: 0, countDelta: 1
    )
    counterSetAgent.counterSet = OcaCounterSet(counter: [OcaCounter(
      id: 1, value: 0, initialValue: 0, role: "GainChanges", notifiers: [counterNotifier.objectNumber]
    )])

    // a channel strip: a gain with a narrower range, a mute and a meter
    let channel = try await SwiftOCADevice.OcaBlock<SwiftOCADevice.OcaWorker>(
      objectNumber: 10100, role: "Channel", deviceDelegate: device
    )
    let channelGain = try await SwiftOCADevice.OcaGain(
      objectNumber: 10101, role: "Gain", deviceDelegate: device, addToRootBlock: false
    )
    channelGain.gain = OcaBoundedPropertyValue(value: 0, in: -60...12)
    let mute = try await SwiftOCADevice.OcaMute(
      objectNumber: 10102, role: "Mute", deviceDelegate: device, addToRootBlock: false
    )
    let level = try await SwiftOCADevice.OcaLevelSensor(
      objectNumber: 10103, role: "Level", deviceDelegate: device, addToRootBlock: false
    )
    for object in [channelGain, mute, level] as [SwiftOCADevice.OcaWorker] {
      try await channel.add(actionObject: object)
    }

    return Objects(
      gain: gain, counterSetAgent: counterSetAgent,
      channelGain: channelGain, mute: mute, level: level
    )
  }

  /// Prints each change to the gains and the mute, whichever protocol made it. Each
  /// sequence starts with the current value, which is not a change.
  private static func report(_ objects: Objects) {
    Task { @OcaDevice in
      var isFirst = true
      do {
        for try await value in objects.gain.$gain {
          if !isFirst {
            print("Block/Gain set to \(value) dB")
            try? objects.counterSetAgent.increment(counter: 1)
          }
          isFirst = false
        }
      } catch {}
    }
    Task { @OcaDevice in
      var isFirst = true
      do {
        for try await value in objects.channelGain.$gain {
          if !isFirst { print("Channel/Gain set to \(value) dB") }
          isFirst = false
        }
      } catch {}
    }
    Task { @OcaDevice in
      var isFirst = true
      do {
        for try await state in objects.mute.$state {
          if !isFirst { print("Channel/Mute set to \(state)") }
          isFirst = false
        }
      } catch {}
    }
  }

  /// Moves the level meter, about ten times a second, so consumers see it change.
  @OcaDevice
  private static func animate(_ level: SwiftOCADevice.OcaLevelSensor) async throws {
    var phase = 0.0
    while !Task.isCancelled {
      phase += 0.15
      let reading = OcaDB(-30 + 24 * sin(phase))
      try await level.update(reading: (reading * 10).rounded() / 10)
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  /// Every IPv4 address on `port`.
  private static func anyAddress(port: UInt16) -> Data {
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    #if canImport(Darwin)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    return withUnsafeBytes(of: address) { Data($0) }
  }
}
