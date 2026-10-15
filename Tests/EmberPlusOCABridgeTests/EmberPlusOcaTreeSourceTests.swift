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
@testable import EmberPlusOCABridge
import Foundation
import Synchronization
@_spi(SwiftOCAPrivate)
import SwiftOCA
@_spi(SwiftOCAPrivate)
import SwiftOCADevice
import XCTest

/// A consumer at the other end of an in-memory transport, which collects what the
/// provider sends as Glow messages.
final class TestConsumer: Sendable {
  private let toProvider: AsyncStream<[UInt8]>.Continuation
  private let fromProvider: AsyncStream<[UInt8]>
  let transport: Transport

  struct Transport: EmberPlusTransport {
    let inbound: AsyncStream<[UInt8]>
    let outbound: AsyncStream<[UInt8]>.Continuation
    let peerDescription = "192.0.2.10:50000"

    func read() async throws -> [UInt8] {
      var iterator = inbound.makeAsyncIterator()
      return await iterator.next() ?? []
    }

    func write(_ bytes: [UInt8]) async throws { outbound.yield(bytes) }
    func close() { outbound.finish() }
  }

  init() {
    let (inbound, toProvider) = AsyncStream.makeStream(of: [UInt8].self)
    let (fromProvider, outbound) = AsyncStream.makeStream(of: [UInt8].self)
    self.toProvider = toProvider
    self.fromProvider = fromProvider
    transport = Transport(inbound: inbound, outbound: outbound)
  }

  func send(_ root: GlowRoot) {
    for packet in S101Message.packets(for: root.encoded()) {
      toProvider.yield(S101.frame(packet.encoded))
    }
  }

  func disconnect() { toProvider.finish() }

  private let inbox = Mutex([GlowRoot]())
  private let reader = Mutex<Task<(), Never>?>(nil)

  /// Starts collecting what the provider sends.
  func listen() {
    let stream = fromProvider
    let task = Task { [self] in
      var deframer = S101.Deframer()
      var reassembler = S101Message.Reassembler()
      for await bytes in stream {
        for case let .message(bytes, _) in deframer.receive(bytes) {
          guard case let .ember(packet)? = try? S101Message(decoding: bytes).command,
                case let .message(payload)? = reassembler.receive(packet),
                let root = try? GlowRoot(decoding: payload) else { continue }
          self.inbox.withLock { $0.append(root) }
        }
      }
    }
    reader.withLock { $0 = task }
  }

  /// The next message, or nil if none comes in time.
  func next(timeout: Duration = .seconds(5)) async -> GlowRoot? {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if let root = inbox.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { return root }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return nil
  }
}

extension GlowRoot {
  var elements: [GlowElement] {
    if case let .elements(elements) = self { return elements }
    return []
  }
}

extension GlowElement {
  var path: GlowPath? {
    if case let .path(path)? = address { return path }
    return nil
  }

  var parameterContents: GlowParameterContents? {
    if case let .parameter(parameter) = self { return parameter.contents }
    return nil
  }

  var nodeContents: GlowNodeContents? {
    if case let .node(node) = self { return node.contents }
    return nil
  }
}

@OcaDevice
enum Fixture {
  private(set) static var block: SwiftOCADevice.OcaBlock<SwiftOCADevice.OcaRoot>!
  private(set) static var gain: SwiftOCADevice.OcaGain!
  private(set) static var mute: SwiftOCADevice.OcaMute!
  private(set) static var level: SwiftOCADevice.OcaLevelSensor!
  private(set) static var matrix: SwiftOCADevice.OcaMatrix<SwiftOCADevice.OcaBooleanActuator>!
  /// The matrix's crosspoints, by target (x) and then source (y).
  private(set) static var crosspoints: [[SwiftOCADevice.OcaBooleanActuator]] = []
  /// An object number with its top bit set, as Inferno's channels have.
  private(set) static var master: SwiftOCADevice.OcaGain!
  private(set) static var source: EmberPlusOcaTreeSource!

  static func make() async throws {
    guard source == nil else { return }
    let device = OcaDevice.shared
    try await device.initializeDefaultObjects()
    block = try await SwiftOCADevice.OcaBlock(role: "Channel", deviceDelegate: device)
    gain = try await SwiftOCADevice.OcaGain(role: "Gain", deviceDelegate: device, addToRootBlock: false)
    mute = try await SwiftOCADevice.OcaMute(role: "Mute", deviceDelegate: device, addToRootBlock: false)
    try await block.add(actionObject: gain)
    try await block.add(actionObject: mute)
    level = try await SwiftOCADevice.OcaLevelSensor(role: "Level", deviceDelegate: device, addToRootBlock: false)
    try await block.add(actionObject: level)
    master = try await SwiftOCADevice.OcaGain(
      objectNumber: 0x8000_1000, role: "Master", deviceDelegate: device, addToRootBlock: false
    )
    try await block.add(actionObject: master)
    // as Inferno numbers a master channel's object for output 0
    let masterMute = try await SwiftOCADevice.OcaMute(
      objectNumber: 0x8000_0008, role: "MasterMute", deviceDelegate: device, addToRootBlock: false
    )
    try await block.add(actionObject: masterMute)
    matrix = try await SwiftOCADevice.OcaMatrix<SwiftOCADevice.OcaBooleanActuator>(
      rows: 2, columns: 2, role: "Router", deviceDelegate: device, addToRootBlock: false
    )
    try await block.add(actionObject: matrix)
    for x in 0..<2 {
      var column = [SwiftOCADevice.OcaBooleanActuator]()
      for y in 0..<2 {
        let crosspoint = try await SwiftOCADevice.OcaBooleanActuator(
          role: "Crosspoint(\(x),\(y))", deviceDelegate: device, addToRootBlock: false
        )
        try await matrix.add(member: crosspoint, at: OcaVector2D(x: OcaMatrixCoordinate(x), y: OcaMatrixCoordinate(y)))
        column.append(crosspoint)
      }
      crosspoints.append(column)
    }
    source = EmberPlusOcaTreeSource(device: device)
  }
}

final class EmberPlusOcaTreeSourceTests: XCTestCase {
  private var consumer: TestConsumer!
  private var serving: Task<(), Never>!
  private var blockPath: GlowPath = []
  private var gainPath: GlowPath = []
  private var mutePath: GlowPath = []
  private var levelPath: GlowPath = []
  private var matrixPath: GlowPath = []
  /// OcaGain's Gain (4.1), and OcaMute's State (4.1).
  private let level4Property: UInt32 = 0x401

  @OcaDevice
  override func setUp() async throws {
    try await Fixture.make()
    Fixture.gain.gain = OcaBoundedPropertyValue(value: 0, in: -144...20)
    Fixture.mute.state = .unmuted
    blockPath = [1, UInt32(Fixture.block.objectNumber)]
    gainPath = blockPath + [UInt32(Fixture.gain.objectNumber)]
    mutePath = blockPath + [UInt32(Fixture.mute.objectNumber)]
    levelPath = blockPath + [UInt32(Fixture.level.objectNumber)]
    matrixPath = blockPath + [UInt32(Fixture.matrix.objectNumber)]
    for crosspoint in Fixture.crosspoints.joined() { crosspoint.setting = false }
    try await Fixture.level.update(reading: -144)
    consumer = TestConsumer()
    consumer.listen()
    let provider = EmberPlusProvider(source: Fixture.source)
    let transport = consumer.transport
    serving = Task { await provider.serve(transport) }
  }

  override func tearDown() async throws {
    consumer.disconnect()
    await serving.value
  }

  private func request(_ root: GlowRoot) async -> GlowRoot? {
    consumer.send(root)
    return await next()
  }

  private func next() async -> GlowRoot? {
    let root = await consumer.next()
    XCTAssertNotNil(root, "no message from the provider")
    return root
  }

  private func getDirectory(_ path: GlowPath) async -> [GlowElement] {
    let command = GlowElement.command(GlowCommand(.getDirectory))
    let root: GlowRoot = path.isEmpty ? .elements([command]) :
      .elements([.node(GlowNode(.path(path), children: [command]))])
    return await request(root)?.elements ?? []
  }

  func testRoot() async throws {
    let root = await getDirectory([])
    XCTAssertEqual(root.count, 1)
    XCTAssertEqual(root.first?.path, [1])
    XCTAssertEqual(root.first?.nodeContents?.identifier, "device")
  }

  func testRootBlockHasManagersAndMembers() async throws {
    let children = await getDirectory([1])
    let identifiers = Dictionary(uniqueKeysWithValues: children.compactMap { element in
      element.nodeContents?.identifier.map { ($0, element.path!) }
    })
    XCTAssertEqual(identifiers["Channel"], blockPath)
    // the device manager is object 1
    XCTAssertTrue(identifiers.values.contains([1, 1]))
  }

  func testBlockMembers() async throws {
    let children = await getDirectory(blockPath)
    let nodes = children.filter { $0.nodeContents != nil }
    XCTAssertEqual(
      Set(nodes.compactMap(\.nodeContents?.identifier)),
      ["Gain", "Mute", "Level", "Master", "MasterMute"]
    )
    XCTAssertEqual(
      Set(nodes.compactMap(\.path)),
      [gainPath, mutePath, levelPath, blockPath + [0x1000], blockPath + [0x7000_0008]]
    )
  }

  func testGainParameter() async throws {
    let children = await getDirectory(gainPath)
    let gain = children.first { $0.path == gainPath + [level4Property] }?.parameterContents
    XCTAssertEqual(gain?.identifier, "gain")
    XCTAssertEqual(gain?.type, .real)
    XCTAssertEqual(gain?.value, .real(0))
    XCTAssertEqual(gain?.minimum, .real(-144))
    XCTAssertEqual(gain?.maximum, .real(20))
    XCTAssertEqual(gain?.access, .readWrite)
    XCTAssertEqual(gain?.format, "%.2f°dB")
    // structured values, such as OcaWorker's ports (2.2), are not presented
    XCTAssertFalse(children.contains { $0.path == gainPath + [0x202] })
    // OcaWorker's owner (2.4) is read only
    let owner = children.first { $0.path == gainPath + [0x204] }?.parameterContents
    XCTAssertEqual(owner?.value, .integer(Int64(blockPath[1])))
    XCTAssertEqual(owner?.access, .read)
  }

  /// OcaRoot's Role (1.5) is served by GetRole alone, and is a parameter all the same;
  /// accessors are not functions.
  func testAccessorsAreParameters() async throws {
    let children = await getDirectory(gainPath)
    let role = children.first { $0.path == gainPath + [0x105] }?.parameterContents
    XCTAssertEqual(role?.identifier, "role")
    XCTAssertEqual(role?.value, .string("Gain"))
    XCTAssertEqual(role?.access, .read)
    let functions = children.compactMap { element -> String? in
      guard case let .function(function) = element else { return nil }
      return function.contents?.identifier
    }
    XCTAssertFalse(functions.contains { $0.hasPrefix("Get") }, "\(functions)")
    // nor are the lock methods presented
    XCTAssertFalse(
      functions.contains { ["SetLockNoReadWrite", "SetLockNoWrite", "Unlock"].contains($0) },
      "\(functions)"
    )
  }

  func testMuteIsAnEnumeration() async throws {
    let children = await getDirectory(mutePath)
    let state = children.first { $0.path == mutePath + [level4Property] }?.parameterContents
    XCTAssertEqual(state?.type, .enum)
    XCTAssertEqual(state?.value, .integer(Int64(OcaMuteState.unmuted.rawValue)))
    XCTAssertEqual(
      state?.enumMap?.map(\.integer).sorted(),
      OcaMuteState.allCases.map { Int32($0.rawValue) }.sorted()
    )
  }

  func testSetValue() async throws {
    let reply = await request(.elements([.parameter(GlowParameter(
      .path(gainPath + [level4Property]),
      contents: GlowParameterContents(value: .real(-6.5))
    ))]))
    XCTAssertEqual(reply?.elements.first?.parameterContents?.value, .real(-6.5))
    let value = await Fixture.gain.gain.value
    XCTAssertEqual(value, -6.5)
  }

  /// A subscribed session that sets a value hears of it once, in the reply, and not again
  /// in the device's notification of the change.
  func testSetIsAnsweredOnce() async throws {
    _ = await getDirectory(gainPath)
    let reply = await request(.elements([.parameter(GlowParameter(
      .path(gainPath + [level4Property]),
      contents: GlowParameterContents(value: .real(-3))
    ))]))
    XCTAssertEqual(reply?.elements.first?.parameterContents?.value, .real(-3))
    let echo = await consumer.next(timeout: .milliseconds(500))
    XCTAssertNil(echo)
  }

  func testOutOfRangeSetAnswersWithCurrentValue() async throws {
    let reply = await request(.elements([.parameter(GlowParameter(
      .path(gainPath + [level4Property]),
      contents: GlowParameterContents(value: .real(100))
    ))]))
    XCTAssertEqual(reply?.elements.first?.parameterContents?.value, .real(0))
  }

  func testReadOnlyParameterIsNotSet() async throws {
    let reply = await request(.elements([.parameter(GlowParameter(
      .path(gainPath + [0x204]),
      contents: GlowParameterContents(value: .integer(1))
    ))]))
    XCTAssertEqual(reply?.elements.first?.parameterContents?.value, .integer(Int64(blockPath[1])))
  }

  func testDeviceChangesAreNotified() async throws {
    _ = await getDirectory(gainPath)
    await Task { @OcaDevice in
      Fixture.gain.gain = OcaBoundedPropertyValue(value: -12, in: -144...20)
    }.value
    let change = await next()
    XCTAssertEqual(change?.elements.first?.path, gainPath + [level4Property])
    XCTAssertEqual(change?.elements.first?.parameterContents?.value, .real(-12))
  }

  /// OcaLevelSensor serves its Reading (4.1) by GetReading alone, with its bounds. A
  /// sensor's reading is a stream: its changes go only to a session that subscribed to
  /// it, as stream entries.
  func testLevelSensorReadingIsAStream() async throws {
    let readingPath = levelPath + [level4Property]
    let children = await getDirectory(levelPath)
    let reading = children.first { $0.path == readingPath }?.parameterContents
    XCTAssertEqual(reading?.identifier, "reading")
    XCTAssertEqual(reading?.value, .real(-144))
    XCTAssertEqual(reading?.minimum, .real(-144))
    XCTAssertEqual(reading?.maximum, .real(0))
    XCTAssertEqual(reading?.access, .read)
    let streamIdentifier = try XCTUnwrap(reading?.streamIdentifier)

    // having its node's directory is not enough
    try await Fixture.level.update(reading: -30)
    var message = await consumer.next(timeout: .milliseconds(300))
    XCTAssertNil(message)

    consumer.send(.elements([.parameter(GlowParameter(
      .path(readingPath),
      children: [.command(GlowCommand(.subscribe))]
    ))]))
    try await Task.sleep(for: .milliseconds(100))
    try await Fixture.level.update(reading: -20)
    message = await next()
    XCTAssertEqual(
      message,
      .streams([GlowStreamEntry(streamIdentifier: streamIdentifier, value: .real(-20))])
    )

    consumer.send(.elements([.parameter(GlowParameter(
      .path(readingPath),
      children: [.command(GlowCommand(.unsubscribe))]
    ))]))
    try await Task.sleep(for: .milliseconds(100))
    try await Fixture.level.update(reading: -10)
    message = await consumer.next(timeout: .milliseconds(300))
    XCTAssertNil(message)
  }

  /// A matrix of boolean actuators is a crosspoint matrix: the actuator at (x, y)
  /// connects source y to target x.
  func testMatrixOfBooleanActuators() async throws {
    let listed = await getDirectory(blockPath).first { $0.path == matrixPath }
    guard case let .matrix(summary)? = listed else { return XCTFail("\(String(describing: listed))") }
    XCTAssertEqual(summary.contents?.identifier, "Router")
    XCTAssertEqual(summary.contents?.targetCount, 2)
    XCTAssertEqual(summary.contents?.sourceCount, 2)
    XCTAssertEqual(summary.contents?.type, .nToN)

    let children = await getDirectory(matrixPath)
    guard case let .matrix(matrix)? = children.first(where: { $0.path == matrixPath }) else {
      return XCTFail("no matrix in \(children)")
    }
    XCTAssertEqual(matrix.targets, [0, 1])
    XCTAssertEqual(matrix.sources, [0, 1])
    XCTAssertEqual(matrix.connections?.map(\.sources), [[], []])
    // the matrix's own properties are its children
    XCTAssertTrue(children.contains { $0.path == matrixPath + [0x105] })

    // connecting source 0 to target 1 sets that crosspoint's actuator, and only that
    let reply = await request(.elements([.matrix(GlowMatrix(
      .path(matrixPath),
      connections: [GlowConnection(target: 1, sources: [0])]
    ))]))
    guard case let .matrix(changed)? = reply?.elements.first else { return XCTFail() }
    XCTAssertEqual(changed.connections, [GlowConnection(target: 1, sources: [0], disposition: .modified)])
    let settings = await Task { @OcaDevice in Fixture.crosspoints.map { $0.map(\.setting) } }.value
    XCTAssertEqual(settings, [[false, false], [true, false]])
    // and is answered once
    let echo = await consumer.next(timeout: .milliseconds(300))
    XCTAssertNil(echo)

    // a crosspoint set by another controller is a changed connection
    await Task { @OcaDevice in Fixture.crosspoints[0][1].setting = true }.value
    let update = await next()
    guard case let .matrix(updated)? = update?.elements.first else { return XCTFail() }
    XCTAssertEqual(updated.connections, [GlowConnection(target: 0, sources: [1])])
  }

  /// A member whose object number has its top bit set is numbered without it.
  func testTopBitIsDropped() async throws {
    let children = await getDirectory(blockPath + [0x1000])
    let gain = children.first { $0.path == blockPath + [0x1000, level4Property] }?.parameterContents
    XCTAssertEqual(gain?.identifier, "gain")
    XCTAssertEqual(gain?.access, .readWrite)
  }

  func testUnknownPathsAnswerNothing() async throws {
    consumer.send(.elements([.node(GlowNode(.path([1, 999_999]), children: [
      .command(GlowCommand(.getDirectory)),
    ]))]))
    // nothing comes back for it, so the next answer is the one after
    let root = await getDirectory([])
    XCTAssertEqual(root.first?.path, [1])
  }

  func testNumbering() {
    XCTAssertEqual(EmberPlusOcaNumbering.number(of: OcaPropertyID("4.1")), 0x401)
    XCTAssertEqual(EmberPlusOcaNumbering.number(of: OcaMethodID("3.12")), 0xB0C)
    XCTAssertNil(EmberPlusOcaNumbering.number(of: OcaPropertyID("9.1")))
    XCTAssertTrue(EmberPlusOcaNumbering.isMember(4096))
    XCTAssertFalse(EmberPlusOcaNumbering.isMember(0x7FF))
    XCTAssertEqual(EmberPlusOcaNumbering.candidates(forMember: 0x8000_1000), [0x1000, 0x7000_1000])
    XCTAssertEqual(
      EmberPlusOcaNumbering.candidates(forMember: 0x1000_0002),
      [0x1000_0002, 0x7000_0002]
    )
    // an Inferno master channel object for output 0 would fold into the property range
    XCTAssertEqual(EmberPlusOcaNumbering.candidates(forMember: 0x8000_0005), [0x7000_0005])
  }
}
