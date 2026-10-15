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

/// The tree a provider serves. The provider owns the connections and the wire format; the
/// source answers each consumer's requests with the elements to send back, and sends
/// value changes to the sessions that should hear of them.
///
/// Requests from one session arrive one at a time, in order; requests from different
/// sessions may arrive concurrently.
public protocol EmberPlusTreeSource: AnyObject, Sendable {
  func sessionStarted(_ session: EmberPlusSession) async
  func sessionEnded(_ session: EmberPlusSession) async

  /// The children of the element at `path` (the root when it is empty), or the element
  /// itself for a parameter, as qualified elements. A node without children reports itself
  /// with no contents, so the consumer can tell its directory was queried. GetDirectory
  /// also registers the session's interest in value changes below `path`.
  func getDirectory(
    _ path: GlowPath,
    fieldMask: GlowFieldFlags,
    session: EmberPlusSession
  ) async -> [GlowElement]

  /// Sets the parameter at `path` and returns it as now is, which is what a consumer is
  /// told whether the change succeeded or not.
  func setValue(
    _ value: GlowValue,
    at path: GlowPath,
    session: EmberPlusSession
  ) async -> [GlowElement]

  func invoke(
    _ invocation: GlowInvocation,
    at path: GlowPath,
    session: EmberPlusSession
  ) async -> GlowInvocationResult?

  /// Required of parameters with a stream identifier, and optional otherwise.
  func subscribe(_ path: GlowPath, session: EmberPlusSession) async
  func unsubscribe(_ path: GlowPath, session: EmberPlusSession) async

  func connect(
    _ connections: [GlowConnection],
    matrix path: GlowPath,
    session: EmberPlusSession
  ) async -> [GlowElement]
}

extension EmberPlusTreeSource {
  public func sessionStarted(_ session: EmberPlusSession) async {}
  public func sessionEnded(_ session: EmberPlusSession) async {}

  public func invoke(
    _ invocation: GlowInvocation,
    at path: GlowPath,
    session: EmberPlusSession
  ) async -> GlowInvocationResult? {
    invocation.invocationID.map { GlowInvocationResult(invocationID: $0, success: false) }
  }

  public func subscribe(_ path: GlowPath, session: EmberPlusSession) async {}
  public func unsubscribe(_ path: GlowPath, session: EmberPlusSession) async {}

  public func connect(
    _ connections: [GlowConnection],
    matrix path: GlowPath,
    session: EmberPlusSession
  ) async -> [GlowElement] {
    []
  }
}
