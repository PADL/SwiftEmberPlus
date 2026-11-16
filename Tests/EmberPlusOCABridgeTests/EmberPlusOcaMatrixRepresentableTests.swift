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
@_spi(SwiftOCAPrivate)
import SwiftOCA
@_spi(SwiftOCAPrivate)
import SwiftOCADevice
import XCTest

/// A router that keeps its routes in a property of its own and presents them as a
/// labelled, non-linear matrix numbered 1 under its node: targets 100 up, sources 200 up.
@OcaDevice
@OcaDeviceClass
final class TestRouter: SwiftOCADevice.OcaAgent, EmberPlusOcaMatrixRepresentable {
  override class var classID: OcaClassID {
    OcaClassID(parent: super.classID, authority: OcaClassID.OcaAllianceCompanyID, 99)
  }

  @OcaDeviceProperty(propertyID: OcaPropertyID("3.1"), getMethodID: OcaMethodID("3.1"))
  var targetNames: [OcaString] = []

  @OcaDeviceProperty(propertyID: OcaPropertyID("3.2"), getMethodID: OcaMethodID("3.2"))
  var sourceNames: [OcaString] = []

  /// Each route as target index << 16 | source index.
  @OcaDeviceProperty(propertyID: OcaPropertyID("3.3"), getMethodID: OcaMethodID("3.3"))
  var routes: [OcaUint32] = []

  /// What the next request is refused with, if anything.
  var refusal: OcaStatus?
  /// The requests applied, in order.
  var requests = [[EmberPlusOcaConnectionChange]]()

  static let matrix = EmberPlusOcaMatrix(
    number: 1,
    identifier: "routes",
    description: "Routes",
    type: .nToN,
    addressingMode: .nonLinear,
    labels: "Name"
  )

  var emberPlusMatrices: [EmberPlusOcaMatrix] {
    [Self.matrix]
  }

  var emberPlusConnectionProperties: Set<OcaPropertyID> {
    [OcaPropertyID("3.3")]
  }

  var emberPlusSignalProperties: Set<OcaPropertyID> {
    [OcaPropertyID("3.1"), OcaPropertyID("3.2")]
  }

  func emberPlusSignals(for matrix: EmberPlusOcaMatrix) -> EmberPlusOcaSignals {
    EmberPlusOcaSignals(
      targets: targetNames.enumerated().map { EmberPlusOcaSignal(Int32(100 + $0), label: $1) },
      sources: sourceNames.enumerated().map { EmberPlusOcaSignal(Int32(200 + $0), label: $1) }
    )
  }

  func emberPlusConnections(
    for matrix: EmberPlusOcaMatrix,
    controller: any OcaController
  ) async -> [Int32: [Int32]] {
    Self.connections(routes)
  }

  func emberPlusConnect(
    _ changes: [EmberPlusOcaConnectionChange],
    matrix: EmberPlusOcaMatrix,
    controller: any OcaController
  ) async throws -> [Int32: [Int32]] {
    if let refusal { throw Ocp1Error.status(refusal) }
    var connections = Self.connections(routes)
    for change in changes {
      connections[change.target] = change.applied(to: connections[change.target] ?? [])
    }
    requests.append(changes)
    routes = connections.keys.sorted().flatMap { target in
      connections[target]!.map { OcaUint32(target - 100) << 16 | OcaUint32($0 - 200) }
    }
    return connections.filter { target, _ in changes.contains { $0.target == target } }
  }

  static func connections(_ routes: [OcaUint32]) -> [Int32: [Int32]] {
    var connections = [Int32: [Int32]]()
    for route in routes {
      connections[Int32(route >> 16) + 100, default: []].append(Int32(route & 0xFFFF) + 200)
    }
    return connections
  }
}

@OcaDevice
enum RouterFixture {
  private(set) static var router: TestRouter!

  static func make() async throws {
    try await Fixture.make()
    guard router == nil else { return }
    router = try await TestRouter(role: "TestRouter", deviceDelegate: OcaDevice.shared)
  }

  static func reset() {
    router.refusal = nil
    router.requests = []
    router.targetNames = ["Out 1", "Out 2"]
    router.sourceNames = ["In 1", "In 2", "In 3"]
    // source 200 to target 100
    router.routes = [0]
  }
}

final class EmberPlusOcaMatrixRepresentableTests: XCTestCase {
  private var consumer: TestConsumer!
  private var serving: Task<(), Never>!
  private var routerPath: GlowPath = []
  private var matrixPath: GlowPath {
    routerPath + [1]
  }

  private var labelsPath: GlowPath {
    matrixPath + [EmberPlusOcaTreeSource.labelsNumber]
  }

  @OcaDevice
  override func setUp() async throws {
    try await RouterFixture.make()
    RouterFixture.reset()
    routerPath = [1, UInt32(RouterFixture.router.objectNumber)]
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
    let root = await consumer.next()
    XCTAssertNotNil(root, "no message from the provider")
    return root
  }

  private func getDirectory(_ path: GlowPath) async -> [GlowElement] {
    await request(.elements([.node(GlowNode(
      .path(path),
      children: [.command(GlowCommand(.getDirectory))]
    ))]))?
      .elements ?? []
  }

  private func matrix(in elements: [GlowElement]) -> GlowMatrix? {
    for case let .matrix(matrix) in elements
      where matrix.address == .path(matrixPath)
    {
      return matrix
    }
    return nil
  }

  private func connect(_ connections: [GlowConnection]) async -> [GlowConnection]? {
    let reply = await request(.elements([.matrix(GlowMatrix(
      .path(matrixPath),
      connections: connections
    ))]))
    return matrix(in: reply?.elements ?? [])?.connections
  }

  func testMatrixIsListedUnderItsObject() async throws {
    let children = await getDirectory(routerPath)
    let listed = try XCTUnwrap(matrix(in: children))
    XCTAssertEqual(listed.contents, GlowMatrixContents(
      identifier: "routes",
      description: "Routes",
      type: .nToN,
      addressingMode: .nonLinear,
      targetCount: 2,
      sourceCount: 3,
      labels: [GlowLabel(basePath: labelsPath, description: "Name")]
    ))
    // the listing names the matrix; its connections come with its own directory
    XCTAssertNil(listed.connections)
  }

  func testMatrixDirectoryHasSignalsAndConnections() async throws {
    let children = await getDirectory(matrixPath)
    let matrix = try XCTUnwrap(matrix(in: children))
    XCTAssertEqual(matrix.contents?.addressingMode, .nonLinear)
    XCTAssertEqual(matrix.targets, [100, 101])
    XCTAssertEqual(matrix.sources, [200, 201, 202])
    XCTAssertEqual(matrix.connections, [
      GlowConnection(target: 100, sources: [200]),
      GlowConnection(target: 101, sources: []),
    ])
    XCTAssertTrue(children.contains { $0.path == labelsPath })
  }

  func testLabels() async {
    let nodes = await getDirectory(labelsPath)
    XCTAssertEqual(nodes.map(\.path), [labelsPath + [1], labelsPath + [2]])
    XCTAssertEqual(nodes.compactMap(\.nodeContents?.identifier), ["targets", "sources"])

    let targets = await getDirectory(labelsPath + [1])
    XCTAssertEqual(targets.map(\.path), [labelsPath + [1, 100], labelsPath + [1, 101]])
    XCTAssertEqual(
      targets.compactMap(\.parameterContents?.value),
      [.string("Out 1"), .string("Out 2")]
    )
    XCTAssertEqual(targets.first?.parameterContents?.type, .string)
    XCTAssertEqual(targets.first?.parameterContents?.access, .read)

    let sources = await getDirectory(labelsPath + [2])
    XCTAssertEqual(
      sources.compactMap(\.parameterContents?.value),
      [.string("In 1"), .string("In 2"), .string("In 3")]
    )
  }

  /// A request is applied as one, and each target asked about is answered once.
  func testConnectIsModified() async {
    _ = await getDirectory(matrixPath)
    let answers = await connect([
      GlowConnection(target: 101, sources: [202], operation: .connect),
      GlowConnection(target: 100, sources: [200], operation: .disconnect),
    ])
    XCTAssertEqual(answers, [
      GlowConnection(target: 101, sources: [202], disposition: .modified),
      GlowConnection(target: 100, sources: [], disposition: .modified),
    ])
    let (routes, requests) = await Task { @OcaDevice in
      (RouterFixture.router.routes, RouterFixture.router.requests)
    }.value
    XCTAssertEqual(routes, [1 << 16 | 2])
    XCTAssertEqual(requests, [[
      EmberPlusOcaConnectionChange(target: 101, sources: [202], operation: .connect),
      EmberPlusOcaConnectionChange(target: 100, sources: [200], operation: .disconnect),
    ]])
    let echo = await consumer.next(timeout: .milliseconds(300))
    XCTAssertNil(echo)
  }

  /// Unknown targets and sources are left out of the request.
  func testUnknownSignalsAreIgnored() async {
    let answers = await connect([
      GlowConnection(target: 7, sources: [200]),
      GlowConnection(target: 101, sources: [201, 999]),
    ])
    XCTAssertEqual(answers, [GlowConnection(target: 101, sources: [201], disposition: .modified)])
  }

  func testRefusalIsLocked() async {
    _ = await getDirectory(matrixPath)
    await Task { @OcaDevice in RouterFixture.router.refusal = .locked }.value
    let answers = await connect([GlowConnection(target: 100, sources: [201])])
    XCTAssertEqual(answers, [GlowConnection(target: 100, sources: [200], disposition: .locked)])
    let routes = await Task { @OcaDevice in RouterFixture.router.routes }.value
    XCTAssertEqual(routes, [0])
  }

  /// Another controller's change is a tally of the targets it changed, and only those.
  func testChangeIsTallied() async {
    _ = await getDirectory(matrixPath)
    await Task { @OcaDevice in RouterFixture.router.routes = [0, 1 << 16 | 1] }.value
    let tally = await consumer.next()
    XCTAssertEqual(
      matrix(in: tally?.elements ?? [])?.connections,
      [GlowConnection(target: 101, sources: [201])]
    )
    XCTAssertNil(matrix(in: tally?.elements ?? [])?.contents)
  }

  /// A change of signals sends the matrix again in full, and the labels the session has.
  func testSignalsChangeIsResent() async throws {
    _ = await getDirectory(matrixPath)
    _ = await getDirectory(labelsPath + [1])
    await Task { @OcaDevice in RouterFixture.router.targetNames = ["Out 1", "Out 2", "Out 3"] }
      .value
    let message = await consumer.next()
    let elements = message?.elements ?? []
    let matrix = try XCTUnwrap(matrix(in: elements))
    XCTAssertEqual(matrix.contents?.targetCount, 3)
    XCTAssertEqual(matrix.targets, [100, 101, 102])
    XCTAssertEqual(matrix.connections?.map(\.target), [100, 101, 102])
    let labels = elements.filter { $0.path?.starts(with: labelsPath + [1]) == true }
    XCTAssertEqual(
      labels.compactMap(\.parameterContents?.value),
      [.string("Out 1"), .string("Out 2"), .string("Out 3")]
    )
  }

  /// Unsubscribing from the matrix stops its tallies.
  func testUnsubscribeStopsTallies() async throws {
    _ = await getDirectory(matrixPath)
    consumer.send(.elements([.matrix(GlowMatrix(
      .path(matrixPath),
      children: [.command(GlowCommand(.unsubscribe))]
    ))]))
    try await Task.sleep(for: .milliseconds(100))
    await Task { @OcaDevice in RouterFixture.router.routes = [] }.value
    let message = await consumer.next(timeout: .milliseconds(300))
    XCTAssertNil(message)
  }
}
