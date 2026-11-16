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
import Foundation

/// A Glow consumer for the command line: walks a provider's tree, reads a matrix with its
/// labels and connections, changes connections and prints the answers, and prints the
/// tallies that follow.
///
///     EmberPlusProbe <host>[:<port>] tree [<path>] [<depth>]
///     EmberPlusProbe <host>[:<port>] matrix <path>
///     EmberPlusProbe <host>[:<port>] connect|disconnect|absolute <path> <target> [<source>...]
///     EmberPlusProbe <host>[:<port>] watch <path> [<seconds>]
///
/// A path is dotted numbers (`1.4096.1`) or identifiers separated by slashes
/// (`device/Bridge/Router/Flows`). Targets and sources are signal numbers or labels.
@main
enum EmberPlusProbe {
  static let usage = """
  usage: EmberPlusProbe <host>[:<port>] tree [<path>] [<depth>]
         EmberPlusProbe <host>[:<port>] matrix <path>
         EmberPlusProbe <host>[:<port>] connect|disconnect|absolute <path> <target> [<source>...]
         EmberPlusProbe <host>[:<port>] watch <path> [<seconds>]
  """

  static func main() async {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 2 else { fail(usage) }
    let (host, port) = endpoint(arguments.removeFirst())
    let command = arguments.removeFirst()
    do {
      let consumer = try await EmberPlusConsumer.connect(host: host, port: port)
      defer { consumer.close() }
      let probe = Probe(consumer: consumer)
      switch command {
      case "tree":
        let path = if let text = arguments.first { try await probe.resolve(text) }
        else { GlowPath() }
        let depth = arguments.dropFirst().first.flatMap(Int.init) ?? Int.max
        try await probe.tree(path, depth: depth)
      case "matrix":
        guard let path = arguments.first else { fail(usage) }
        let matrix = try await probe.matrix(at: probe.resolve(path))
        probe.show(matrix)
      case "connect", "disconnect", "absolute":
        guard arguments.count >= 2 else { fail(usage) }
        let matrix = try await probe.matrix(at: probe.resolve(arguments[0]))
        let operation: GlowConnectionOperation = switch command {
        case "connect": .connect
        case "disconnect": .disconnect
        default: .absolute
        }
        try await probe.change(
          matrix,
          target: arguments[1],
          sources: Array(arguments.dropFirst(2)),
          operation: operation
        )
      case "watch":
        guard let path = arguments.first else { fail(usage) }
        let seconds = arguments.dropFirst().first.flatMap(Double.init) ?? .infinity
        let matrix = try await probe.matrix(at: probe.resolve(path))
        probe.show(matrix)
        await probe.watch(matrix, for: seconds)
      default:
        fail(usage)
      }
    } catch {
      fail("\(host):\(port): \(error)")
    }
  }

  static func endpoint(_ argument: String) -> (String, UInt16) {
    guard let colon = argument.lastIndex(of: ":"), !argument.hasSuffix("]"),
          argument.filter({ $0 == ":" }).count == 1,
          let port = UInt16(argument[argument.index(after: colon)...])
    else { return (argument, 9000) }
    return (String(argument[..<colon]), port)
  }

  static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
  }
}

struct ProbeError: Error, CustomStringConvertible {
  let description: String
}

/// A matrix as read: its contents, signals, labels and connections.
struct Matrix {
  let path: GlowPath
  let contents: GlowMatrixContents?
  let targets: [Int32]
  let sources: [Int32]
  var connections: [Int32: [UInt32]]
  let targetLabels: [Int32: String]
  let sourceLabels: [Int32: String]

  func targetName(_ number: Int32) -> String {
    targetLabels[number].map { "\(number) \($0)" } ?? "\(number)"
  }

  func sourceName(_ number: Int32) -> String {
    sourceLabels[number].map { "\(number) \($0)" } ?? "\(number)"
  }

  func sourceNames(_ numbers: [UInt32]?) -> String {
    "[" + (numbers ?? []).map { sourceName(Int32(clamping: $0)) }.joined(separator: ", ") + "]"
  }

  /// A signal by number or by label.
  func signal(_ name: String, targets isTarget: Bool) throws -> Int32 {
    if let number = Int32(name) { return number }
    let labels = isTarget ? targetLabels : sourceLabels
    guard let number = labels.first(where: { $0.value == name })?.key else {
      throw ProbeError(description: "no \(isTarget ? "target" : "source") labelled \(name)")
    }
    return number
  }
}

struct Probe {
  let consumer: EmberPlusConsumer

  static func dotted(_ path: GlowPath) -> String {
    path.map(String.init).joined(separator: ".")
  }

  /// A dotted path, or identifiers resolved by walking from the root.
  func resolve(_ text: String) async throws -> GlowPath {
    if text.allSatisfy({ $0.isNumber || $0 == "." }) {
      return text.split(separator: ".").compactMap { UInt32($0) }
    }
    var path = GlowPath()
    for identifier in text.split(separator: "/") {
      let children = try await consumer.getDirectory(path)
      guard let child = children.first(where: { Self.identifier(of: $0) == String(identifier) }),
            case let .path(childPath)? = child.address
      else {
        throw ProbeError(description: "no \(identifier) under \(Self.dotted(path))")
      }
      path = childPath
    }
    return path
  }

  static func identifier(of element: GlowElement) -> String? {
    switch element {
    case let .node(node): node.contents?.identifier
    case let .parameter(parameter): parameter.contents?.identifier
    case let .function(function): function.contents?.identifier
    case let .matrix(matrix): matrix.contents?.identifier
    default: nil
    }
  }

  func tree(_ path: GlowPath, depth: Int, indent: String = "") async throws {
    guard depth > 0 else { return }
    for element in try await consumer.getDirectory(path) {
      guard case let .path(elementPath)? = element.address, elementPath != path else { continue }
      print(indent + Self.describe(element, at: elementPath))
      if case .node = element {
        try await tree(elementPath, depth: depth - 1, indent: indent + "  ")
      }
    }
  }

  static func describe(_ element: GlowElement, at path: GlowPath) -> String {
    let name = "\(dotted(path)) \(identifier(of: element) ?? "")"
    switch element {
    case .node:
      return "\(name)/"
    case let .parameter(parameter):
      return "\(name) = \(parameter.contents?.value.map { "\($0)" } ?? "-")"
    case .function:
      return "\(name)()"
    case let .matrix(matrix):
      let contents = matrix.contents
      return "\(name) [matrix \(contents?.targetCount ?? 0)x\(contents?.sourceCount ?? 0)]"
    default:
      return name
    }
  }

  /// A matrix's directory, and its labels if it has any.
  func matrix(at path: GlowPath) async throws -> Matrix {
    let children = try await consumer.getDirectory(path)
    guard let found = children.lazy.compactMap({ element -> GlowMatrix? in
      guard case let .matrix(matrix) = element, matrix.address == .path(path) else { return nil }
      return matrix
    }).first else { throw ProbeError(description: "\(Self.dotted(path)) is not a matrix") }
    var targetLabels = [Int32: String]()
    var sourceLabels = [Int32: String]()
    if let base = found.contents?.labels?.first?.basePath {
      targetLabels = try await labels(at: base + [1])
      sourceLabels = try await labels(at: base + [2])
    }
    let targetCount = Int(found.contents?.targetCount ?? 0)
    let sourceCount = Int(found.contents?.sourceCount ?? 0)
    return Matrix(
      path: path,
      contents: found.contents,
      targets: found.targets ?? (0..<Int32(targetCount)).map { $0 },
      sources: found.sources ?? (0..<Int32(sourceCount)).map { $0 },
      connections: Dictionary(
        (found.connections ?? []).map { ($0.target, $0.sources ?? []) },
        uniquingKeysWith: { $1 }
      ),
      targetLabels: targetLabels,
      sourceLabels: sourceLabels
    )
  }

  private func labels(at path: GlowPath) async throws -> [Int32: String] {
    var labels = [Int32: String]()
    for case let .parameter(parameter) in try await consumer.getDirectory(path) {
      guard case let .path(labelPath) = parameter.address, labelPath.count == path.count + 1,
            let number = labelPath.last.flatMap({ Int32(exactly: $0) }),
            case let .string(label)? = parameter.contents?.value else { continue }
      labels[number] = label
    }
    return labels
  }

  func show(_ matrix: Matrix) {
    let contents = matrix.contents
    print(
      "matrix \(contents?.identifier ?? "") at \(Self.dotted(matrix.path)):",
      "type \(contents?.type?.rawValue ?? 0) (0 oneToN, 1 oneToOne, 2 nToN),",
      "addressing \(contents?.addressingMode?.rawValue ?? 0) (0 linear, 1 nonLinear),",
      "\(matrix.targets.count) targets, \(matrix.sources.count) sources"
    )
    print("sources:")
    for source in matrix.sources {
      print("  \(matrix.sourceName(source))")
    }
    print("targets <- connected sources:")
    for target in matrix.targets {
      print("  \(matrix.targetName(target)) <- \(matrix.sourceNames(matrix.connections[target]))")
    }
  }

  func change(
    _ matrix: Matrix,
    target: String,
    sources: [String],
    operation: GlowConnectionOperation
  ) async throws {
    let target = try matrix.signal(target, targets: true)
    let sources = try sources.map { try UInt32(matrix.signal($0, targets: false)) }
    let answers = try await consumer.connect(
      [GlowConnection(target: target, sources: sources, operation: operation)],
      matrix: matrix.path
    )
    for answer in answers {
      print(
        "\(matrix.targetName(answer.target)): \(Self.name(of: answer.disposition)) \(matrix.sourceNames(answer.sources))"
      )
    }
  }

  static func name(of disposition: GlowConnectionDisposition?) -> String {
    switch disposition ?? .tally {
    case .tally: "tally"
    case .modified: "modified"
    case .pending: "pending"
    case .locked: "locked"
    default: "disposition \(disposition!.rawValue)"
    }
  }

  /// Prints each change of the matrix as it arrives, until the time is up.
  func watch(_ matrix: Matrix, for seconds: Double) async {
    let deadline = seconds.isFinite ? ContinuousClock.now + .milliseconds(Int(seconds * 1000)) : nil
    while deadline.map({ ContinuousClock.now < $0 }) ?? true {
      let wait = deadline.map { min(.seconds(60), $0 - ContinuousClock.now) } ?? .seconds(60)
      guard let root = await consumer.next(timeout: wait) else { continue }
      guard case let .elements(elements) = root else { continue }
      for element in elements {
        guard case let .path(path)? = element.address else { continue }
        if case let .matrix(changed) = element, path == matrix.path {
          if changed
            .contents !=
            nil
          {
            print(
              "signals changed: \(changed.targets?.count ?? 0) targets, \(changed.sources?.count ?? 0) sources"
            )
          }
          for connection in changed.connections ?? [] {
            print(
              "\(matrix.targetName(connection.target)): \(Self.name(of: connection.disposition)) \(matrix.sourceNames(connection.sources))"
            )
          }
        } else {
          print(Self.describe(element, at: path))
        }
      }
    }
  }
}
