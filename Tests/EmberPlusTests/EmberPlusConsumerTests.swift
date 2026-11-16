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

@testable import EmberPlus
import XCTest

final class EmberPlusConsumerTests: XCTestCase {
  /// A consumer connected over TCP (to the listener's IPv6 loopback) reads the tree, and
  /// hears of another consumer's change while waiting for nothing in particular.
  func testConsumerOverTCP() async throws {
    let source = TestTreeSource()
    let provider = EmberPlusProvider(source: source)
    let listener = try EmberPlusListener(port: 0, loopback: true)
    let serving = Task { try await provider.serve(listener: listener) }
    defer { serving.cancel() }

    let consumer = try await EmberPlusConsumer.connect(host: "::1", port: listener.port)
    defer { consumer.close() }
    let root = try await consumer.getDirectory([])
    XCTAssertEqual(root, [.node(GlowNode(.path([1]), contents: GlowNodeContents(identifier: "device")))])
    let device = try await consumer.getDirectory([1])
    XCTAssertEqual(device.map(\.address), [.path([1, 1]), .path([1, 2])])

    let other = try await EmberPlusConsumer.connect(host: "::1", port: listener.port)
    defer { other.close() }
    try await other.send(.elements([.parameter(GlowParameter(
      .path([1, 1]),
      contents: GlowParameterContents(value: .real(-6))
    ))]))
    let change = await consumer.next()
    guard case let .elements(elements)? = change, case let .parameter(gain)? = elements.first else {
      return XCTFail("no change: \(String(describing: change))")
    }
    XCTAssertEqual(gain.contents?.value, .real(-6))
  }

  func testUnknownHostIsNotFound() async throws {
    do {
      _ = try await EmberPlusConsumer.connect(host: "no-such-host.invalid", port: 9000)
      XCTFail("connected")
    } catch is EmberPlusHostNotFound {}
  }

  /// A request nobody answers times out rather than waiting for ever.
  func testUnansweredRequestTimesOut() async throws {
    let consumer = TestConsumer()
    let client = EmberPlusConsumer(transport: consumer.transport)
    defer { client.close() }
    do {
      _ = try await client.getDirectory([9], timeout: .milliseconds(100))
      XCTFail("answered")
    } catch EmberPlusConsumer.Error.timedOut {}
  }
}
