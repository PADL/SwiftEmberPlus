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

/// One thing a consumer asks of a provider, wherever in a message it was nested.
public enum EmberPlusRequest: Sendable, Hashable {
  case getDirectory(GlowPath, GlowFieldFlags)
  case subscribe(GlowPath)
  case unsubscribe(GlowPath)
  case invoke(GlowPath, GlowInvocation)
  /// A parameter that arrives with a value is a request to set it.
  case setValue(GlowPath, GlowValue)
  case connect(GlowPath, [GlowConnection])

  /// The requests in a message, in the order they appear, resolving numbered elements to
  /// paths through their parents (as `GlowWalker` does in EmberLib.net).
  public static func requests(in root: GlowRoot) -> [EmberPlusRequest] {
    guard case let .elements(elements) = root else { return [] }
    var requests = [EmberPlusRequest]()
    for element in elements {
      collect(element, parent: [], into: &requests)
    }
    return requests
  }

  private static func collect(
    _ element: GlowElement,
    parent: GlowPath,
    into requests: inout [EmberPlusRequest]
  ) {
    let path: GlowPath
    switch element.address {
    case let .number(number)?:
      guard let arc = UInt32(exactly: number) else { return }
      path = parent + [arc]
    case let .path(qualified)?:
      path = qualified
    case nil:
      path = parent
    }

    switch element {
    case let .command(command):
      switch command.number {
      case .getDirectory:
        requests.append(.getDirectory(path, command.dirFieldMask ?? .default))
      case .subscribe:
        requests.append(.subscribe(path))
      case .unsubscribe:
        requests.append(.unsubscribe(path))
      case .invoke:
        requests.append(.invoke(path, command.invocation ?? GlowInvocation()))
      default:
        break
      }
    case let .parameter(parameter):
      if let value = parameter.contents?.value {
        requests.append(.setValue(path, value))
      }
    case let .matrix(matrix):
      if let connections = matrix.connections, !connections.isEmpty {
        requests.append(.connect(path, connections))
      }
    default:
      break
    }

    for child in element.children ?? [] {
      collect(child, parent: path, into: &requests)
    }
  }
}
