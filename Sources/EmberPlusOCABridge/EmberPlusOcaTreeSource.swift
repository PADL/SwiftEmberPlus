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
import Logging
@_spi(SwiftOCAPrivate)
import SwiftOCA
@_spi(SwiftOCAPrivate)
import SwiftOCADevice

/// The objects of an OCA device as an Ember+ tree. Nothing of the tree is kept here: each
/// request is answered from the device as it is now.
///
/// The root block is node 1. Under an object's node are its properties as parameters and
/// its methods as functions; under a block's node are also its members, and under the root
/// block's, the managers (see `EmberPlusOcaNumbering`).
///
/// Each Ember+ session is a controller of its own to the device, which reads and writes
/// properties and invokes methods by sending objects their own commands, as an OCP.2
/// controller would, so locks, access checks and whatever the object does on a set all
/// still apply. A session that has asked for an object's directory hears of changes to
/// its properties, as the device tells the session's controller of them.
@OcaDevice
public final class EmberPlusOcaTreeSource: EmberPlusTreeSource {
  /// The node the root block is.
  public static let rootNumber: UInt32 = 1

  private struct Session {
    let session: EmberPlusSession
    let controller: EmberPlusOcaController
    /// The objects the session hears of, with the path of each object's node.
    var subscribed = [OcaONo: GlowPath]()
    /// What the session was last told of each parameter, so a change is sent once.
    var told = [GlowPath: GlowValue]()
    /// The parameters the session is setting, whose replies tell it of the change, so
    /// the device's own notification of it is not sent as well.
    var setting = Set<GlowPath>()
    /// The stream parameters the session has subscribed to.
    var streams = Set<GlowPath>()
    /// The matrices the session has the directories of, by path.
    var matrices = [GlowPath: MatrixKey]()
    /// The label nodes the session has the directories of, by path.
    var labelNodes = [GlowPath: (matrix: MatrixKey, side: LabelSide)]()
    /// The objects whose property changes the device sends the session's controller.
    var hearing = Set<OcaONo>()
    /// The matrices the session is changing the connections of, whose replies tell it of
    /// the change.
    var connecting = Set<GlowPath>()
    /// The sources the session was last told each matrix target has.
    var toldConnections = [GlowPath: [Int32: [Int32]]]()

    /// Whether anything the session has the directory of hears of the object.
    func hears(_ objectNumber: OcaONo) -> Bool {
      subscribed[objectNumber] != nil
        || matrices.values.contains { $0.emitters.contains(objectNumber) }
        || labelNodes.values.contains { $0.matrix.emitters.contains(objectNumber) }
    }
  }

  /// A matrix as a session knows it: its object, its number there, and the objects whose
  /// property changes may change it.
  private struct MatrixKey {
    let objectNumber: OcaONo
    let number: UInt32?
    let emitters: Set<OcaONo>
  }

  /// A label node under a matrix's label base (Ember+ 1.1: targets 1, sources 2).
  private enum LabelSide: UInt32 {
    case targets = 1
    case sources = 2
  }

  /// The number of a matrix's label base under the matrix.
  nonisolated static let labelsNumber: UInt32 = 1

  private typealias Presenter = any EmberPlusOcaMatrixRepresentable

  private enum Element {
    case object(SwiftOCADevice.OcaRoot)
    case parameter(SwiftOCADevice.OcaRoot, EmberPlusOcaParameter)
    case function(SwiftOCADevice.OcaRoot, EmberPlusOcaFunction)
    /// A matrix numbered under its object's node.
    case matrix(Presenter, EmberPlusOcaMatrix)
    case labels(Presenter, EmberPlusOcaMatrix)
    case labelNode(Presenter, EmberPlusOcaMatrix, LabelSide)
    case label(Presenter, EmberPlusOcaMatrix, LabelSide, Int32)
  }

  private let device: OcaDevice
  private let rootIdentifier: String
  private let presentsStructuredValues: Bool
  private let logger: Logger
  private let endpoint = EmberPlusOcaEndpoint()
  private var endpointRegistration: Task<(), Never>?
  private var sessions = [UInt64: Session]()
  private var classes = [ObjectIdentifier: EmberPlusOcaClass]()

  /// A stream parameter: its object, and its number under the object.
  private struct StreamKey: Hashable {
    let objectNumber: OcaONo
    let number: UInt32
  }

  /// Stream identifiers are unique across the provider and never negative; each stream
  /// keeps its identifier for as long as the provider runs, and consumers learn it from
  /// the parameter.
  private var streamIdentifiers = [StreamKey: Int32]()

  public nonisolated init(
    device: OcaDevice = .shared,
    rootIdentifier: String = "device",
    presentsStructuredValues: Bool = false,
    logger: Logger = Logger(label: "com.padl.EmberPlusOCABridge")
  ) {
    self.device = device
    self.rootIdentifier = rootIdentifier
    self.presentsStructuredValues = presentsStructuredValues
    self.logger = logger
  }

  // MARK: - The tree

  private func presentation(of object: SwiftOCADevice.OcaRoot) -> EmberPlusOcaClass {
    let key = ObjectIdentifier(type(of: object))
    if let known = classes[key] { return known }
    let presentation = EmberPlusOcaClass(
      of: object,
      presentsStructuredValues: presentsStructuredValues,
      logger: logger
    )
    classes[key] = presentation
    return presentation
  }

  /// An object's members by number: for the root block the managers, then the action
  /// objects of a block.
  private func members(of object: SwiftOCADevice.OcaRoot) async -> [(UInt32, SwiftOCADevice.OcaRoot)] {
    var members = [(UInt32, SwiftOCADevice.OcaRoot)]()
    var seen = Set<UInt32>()
    // an object is a member once: the root block may list a manager among its members
    var listed = Set<OcaONo>()
    if object === (await device.rootBlock) {
      for manager in await device.managers {
        let number = UInt32(manager.objectNumber)
        if EmberPlusOcaNumbering.isManager(number), seen.insert(number).inserted {
          listed.insert(manager.objectNumber)
          members.append((number, manager))
        }
      }
    }
    if let block = object as? any OcaBlockContainer {
      for member in block.actionObjects where listed.insert(member.objectNumber).inserted {
        guard let number = EmberPlusOcaNumbering.candidates(forMember: member.objectNumber)
          .first(where: { !seen.contains($0) })
        else {
          logger.warning("not presenting object \(member.objectNumber): no number is free for it")
          continue
        }
        seen.insert(number)
        members.append((number, member))
      }
    }
    return members
  }

  /// The identifiers of an object's members, which have to be unique beside each other
  /// and beside the object's parameters and functions, may not contain a slash, and
  /// begin with a letter or an underscore.
  private func identifiers(
    of members: [(UInt32, SwiftOCADevice.OcaRoot)],
    beside presentation: EmberPlusOcaClass
  ) -> [UInt32: String] {
    var taken = Set(presentation.parameters.map(\.identifier) + presentation.functions.map(\.identifier))
    var identifiers = [UInt32: String]()
    for (number, member) in members {
      var identifier = member.role.replacingOccurrences(of: "/", with: "_")
      if identifier.first.map({ !($0.isLetter || $0 == "_") }) ?? true {
        identifier = "_" + identifier
      }
      if !taken.insert(identifier).inserted {
        identifier += "_\(number)"
        taken.insert(identifier)
      }
      identifiers[number] = identifier
    }
    return identifiers
  }

  private func resolve(_ path: GlowPath) async -> Element? {
    guard path.first == Self.rootNumber, let root = await device.rootBlock else { return nil }
    var object: SwiftOCADevice.OcaRoot = root
    var arcs = path.dropFirst()
    while let number = arcs.first {
      guard let member = await members(of: object).first(where: { $0.0 == number })?.1 else {
        return resolve(Array(arcs), below: object)
      }
      object = member
      arcs = arcs.dropFirst()
    }
    return .object(object)
  }

  /// What is below an object's node that is not a member: a parameter or function, or a
  /// matrix of the object's and its labels.
  private func resolve(_ arcs: [UInt32], below object: SwiftOCADevice.OcaRoot) -> Element? {
    if arcs.count == 1 {
      let presentation = presentation(of: object)
      if let parameter = presentation.parameter(arcs[0]) { return .parameter(object, parameter) }
      if let function = presentation.function(arcs[0]) { return .function(object, function) }
    }
    guard let presenter = object as? Presenter else { return nil }
    let matrices = presenter.emberPlusMatrices
    var rest = arcs[...]
    let matrix: EmberPlusOcaMatrix
    if Self.isMatrixNumber(arcs[0]), let numbered = matrices.first(where: { $0.number == arcs[0] }) {
      matrix = numbered
      rest = rest.dropFirst()
      if rest.isEmpty { return .matrix(presenter, matrix) }
    } else if let own = matrices.first(where: { $0.number == nil }) {
      matrix = own
    } else {
      return nil
    }
    guard matrix.labels != nil, rest.first == Self.labelsNumber else { return nil }
    rest = rest.dropFirst()
    guard let side = rest.first else { return .labels(presenter, matrix) }
    guard let side = LabelSide(rawValue: side) else { return nil }
    rest = rest.dropFirst()
    guard let signal = rest.first else { return .labelNode(presenter, matrix, side) }
    guard rest.count == 1, let number = Int32(exactly: signal) else { return nil }
    return .label(presenter, matrix, side, number)
  }

  /// A matrix's number under its object's node, below the numbers of its properties.
  private static func isMatrixNumber(_ number: UInt32) -> Bool { (1..<0x100).contains(number) }

  // MARK: - Describing

  private func node(
    _ object: SwiftOCADevice.OcaRoot,
    at path: GlowPath,
    identifier: String
  ) -> GlowElement {
    .node(GlowNode(.path(path), contents: GlowNodeContents(
      identifier: identifier,
      description: object.role.isEmpty ? nil : object.role,
      isOnline: true
    )))
  }

  private func describe(
    _ parameter: EmberPlusOcaParameter,
    of object: SwiftOCADevice.OcaRoot,
    at path: GlowPath,
    for state: Session
  ) async -> (GlowElement, GlowValue?) {
    let (value, minimum, maximum) = await read(parameter, of: object, as: state.controller)
    var contents = GlowParameterContents(
      identifier: parameter.identifier,
      description: parameter.identifier,
      value: value,
      minimum: minimum,
      maximum: maximum,
      access: parameter.isWritable ? .readWrite : .read,
      format: emberPlusFormat(typeName: parameter.typeName),
      isOnline: true,
      type: parameter.type.parameterType
    )
    if parameter.isStream {
      contents.streamIdentifier = streamIdentifier(of: parameter, of: object)
    }
    if let cases = parameter.type.enumeration {
      contents.enumMap = cases.compactMap { name, value in
        Int32(exactly: value).map { GlowStringIntegerPair(name, $0) }
      }
      // consumers before enumMap take the names of values 0 to N, one per line
      if cases.map(\.value) == Array(0..<Int64(cases.count)) {
        contents.enumeration = cases.map(\.name).joined(separator: "\n")
      }
    }
    return (.parameter(GlowParameter(.path(path), contents: contents)), value)
  }

  private func streamIdentifier(
    of parameter: EmberPlusOcaParameter,
    of object: SwiftOCADevice.OcaRoot
  ) -> Int32 {
    let key = StreamKey(objectNumber: object.objectNumber, number: parameter.number)
    if let known = streamIdentifiers[key] { return known }
    let identifier = Int32(streamIdentifiers.count + 1)
    streamIdentifiers[key] = identifier
    return identifier
  }

  private func describe(_ function: EmberPlusOcaFunction, at path: GlowPath) -> GlowElement {
    .function(GlowFunction(.path(path), contents: GlowFunctionContents(
      identifier: function.identifier,
      description: function.identifier,
      arguments: function.parameters.map {
        GlowTupleItemDescription(type: $0.type.parameterType, name: $0.name)
      },
      result: function.results.map {
        GlowTupleItemDescription(type: $0.type.parameterType, name: $0.name)
      }
    )))
  }

  /// A parameter with only its value, and its range if it has one, as a change is told.
  private func update(
    _ parameter: EmberPlusOcaParameter,
    of object: SwiftOCADevice.OcaRoot,
    at path: GlowPath,
    as controller: EmberPlusOcaController
  ) async -> (GlowElement, GlowValue?) {
    let (value, minimum, maximum) = await read(parameter, of: object, as: controller)
    return (.parameter(GlowParameter(.path(path), contents: GlowParameterContents(
      value: value,
      minimum: minimum,
      maximum: maximum
    ))), value)
  }

  // MARK: - Reading and writing

  private func send(
    _ method: OcaMethodID,
    to object: SwiftOCADevice.OcaRoot,
    _ parameters: [String: Any] = [:],
    as controller: EmberPlusOcaController
  ) async -> (OcaStatus, [String: any Sendable]?) {
    await device.send(method, to: object.objectNumber, ocp2Parameters: parameters, from: controller)
  }

  /// A parameter's value, and the bounds of a bounded property, as the getter answers.
  private func read(
    _ parameter: EmberPlusOcaParameter,
    of object: SwiftOCADevice.OcaRoot,
    as controller: EmberPlusOcaController
  ) async -> (GlowValue?, GlowMinMax?, GlowMinMax?) {
    guard let getter = parameter.getMethodID else { return (nil, nil, nil) }
    let (status, answer) = await send(getter, to: object, as: controller)
    guard status == .ok, let answer else {
      logger.debug("\(controller) reading \(parameter.identifier) failed: \(status)")
      return (nil, nil, nil)
    }
    var names = [String]()
    var value: Any?
    switch parameter.accessors {
    case let .property(_, component?):
      value = answer[component]
    case let .property(descriptor, nil):
      names = descriptor.ocp2GetNames
      if let name = names.first {
        value = answer[name]
      } else {
        // a record's fields name themselves
        value = answer
      }
    case let .methods(_, result, bounds, _):
      value = answer[result]
      if let bounds { names = [result, bounds.minimum, bounds.maximum] }
    }
    if value == nil, answer.count == 1, let only = answer.values.first {
      value = only
    }
    let glowValue = value.flatMap { parameter.type.glowValue(ocp2: $0) }
    guard parameter.isBounded, names.count == 3 else { return (glowValue, nil, nil) }
    return (
      glowValue,
      answer[names[1]].flatMap { parameter.type.glowMinMax(ocp2: $0) },
      answer[names[2]].flatMap { parameter.type.glowMinMax(ocp2: $0) }
    )
  }

  private func write(
    _ value: GlowValue,
    to parameter: EmberPlusOcaParameter,
    of object: SwiftOCADevice.OcaRoot,
    as controller: EmberPlusOcaController
  ) async -> OcaStatus {
    guard parameter.isWritable else { return .permissionDenied }
    guard let converted = parameter.type.ocp2Value(value) else { return .parameterError }
    switch parameter.accessors {
    case let .property(descriptor, component):
      guard let setter = descriptor.setMethodID else { return .permissionDenied }
      var parameters = [String: Any]()
      if let component {
        // the setter takes the pair, so the other component is sent back as it reads
        guard let getter = descriptor.getMethodID else { return .permissionDenied }
        let (status, pair) = await send(getter, to: object, as: controller)
        guard status == .ok, let pair else { return status }
        parameters = pair
        parameters[component] = converted
      } else {
        parameters[descriptor.ocp2SetName] = converted
      }
      return await send(setter, to: object, parameters, as: controller).0
    case let .methods(_, _, _, set?):
      return await send(set.0, to: object, [set.parameter: converted], as: controller).0
    case .methods(_, _, _, nil):
      return .permissionDenied
    }
  }

  // MARK: - EmberPlusTreeSource

  public nonisolated func sessionStarted(_ session: EmberPlusSession) async {
    await started(session)
  }

  public nonisolated func sessionEnded(_ session: EmberPlusSession) async {
    await ended(session)
  }

  public nonisolated func getDirectory(
    _ path: GlowPath,
    fieldMask: GlowFieldFlags,
    session: EmberPlusSession
  ) async -> [GlowElement] {
    await directory(path, session: session)
  }

  public nonisolated func setValue(
    _ value: GlowValue,
    at path: GlowPath,
    session: EmberPlusSession
  ) async -> [GlowElement] {
    await set(value, at: path, session: session)
  }

  public nonisolated func invoke(
    _ invocation: GlowInvocation,
    at path: GlowPath,
    session: EmberPlusSession
  ) async -> GlowInvocationResult? {
    await call(invocation, at: path, session: session)
  }

  public nonisolated func subscribe(_ path: GlowPath, session: EmberPlusSession) async {
    await subscribe(to: path, session: session)
  }

  public nonisolated func unsubscribe(_ path: GlowPath, session: EmberPlusSession) async {
    await unsubscribe(from: path, session: session)
  }

  public nonisolated func connect(
    _ connections: [GlowConnection],
    matrix path: GlowPath,
    session: EmberPlusSession
  ) async -> [GlowElement] {
    await change(connections, of: path, session: session)
  }

  // MARK: - Requests

  private func started(_ session: EmberPlusSession) async {
    let id = session.id
    let controller = EmberPlusOcaController(session: session) { [weak self] objectNumber, property in
      await self?.changed(property, of: objectNumber, session: id)
    }
    sessions[id] = Session(session: session, controller: controller)
    if endpointRegistration == nil {
      endpointRegistration = Task { [device, endpoint, logger] in
        do { try await device.add(endpoint: endpoint) } catch {
          logger.error("not receiving events: the device refused the Ember+ endpoint: \(error)")
        }
      }
    }
    await endpointRegistration?.value
    endpoint.add(controller)
    logger.debug("\(controller) is a controller of the device")
  }

  private func ended(_ session: EmberPlusSession) async {
    guard let ended = sessions.removeValue(forKey: session.id) else { return }
    endpoint.remove(ended.controller)
    await device.expire(controller: ended.controller)
    logger.debug("\(ended.controller) is gone")
  }

  private func directory(_ path: GlowPath, session: EmberPlusSession) async -> [GlowElement] {
    guard let state = sessions[session.id] else { return [] }
    if path.isEmpty {
      guard let root = await device.rootBlock else { return [] }
      return [node(root, at: [Self.rootNumber], identifier: rootIdentifier)]
    }
    switch await resolve(path) {
    case let .object(object):
      await subscribe(object, at: path, session: session.id)
      var children = [GlowElement]()
      let presentation = presentation(of: object)
      let members = await members(of: object)
      let identifiers = identifiers(of: members, beside: presentation)
      if let presenter = object as? Presenter {
        children += await matrices(for: presenter, at: path, session: session.id)
      }
      for (number, member) in members {
        let identifier = identifiers[number]!
        if let presenter = member as? Presenter,
           let own = presenter.emberPlusMatrices.first(where: { $0.number == nil })
        {
          children.append(.matrix(GlowMatrix(.path(path + [number]), contents: matrixContents(
            own,
            for: presenter,
            at: path + [number],
            identifier: identifier,
            signals: presenter.emberPlusSignals(for: own)
          ))))
        } else {
          children.append(node(member, at: path + [number], identifier: identifier))
        }
      }
      for parameter in presentation.parameters {
        let parameterPath = path + [parameter.number]
        let (element, value) = await describe(parameter, of: object, at: parameterPath, for: state)
        children.append(element)
        sessions[session.id]?.told[parameterPath] = value
      }
      for function in presentation.functions {
        children.append(describe(function, at: path + [function.number]))
      }
      // a node with no children answers with itself and no contents
      return children.isEmpty ? [.node(GlowNode(.path(path)))] : children
    case let .parameter(object, parameter):
      await subscribe(object, at: Array(path.dropLast()), session: session.id)
      let (element, value) = await describe(parameter, of: object, at: path, for: state)
      sessions[session.id]?.told[path] = value
      return [element]
    case let .function(_, function):
      return [describe(function, at: path)]
    case let .matrix(presenter, matrix):
      let identifier = matrixIdentifier(matrix, objectIdentifier: "")
      var elements = [
        await self.matrix(
          matrix, for: presenter, at: path, identifier: identifier, session: session.id
        ),
      ]
      if matrix.labels != nil {
        elements.append(labelNode(at: path + [Self.labelsNumber], identifier: "labels"))
      }
      return elements
    case .labels:
      return [
        labelNode(at: path + [LabelSide.targets.rawValue], identifier: "targets"),
        labelNode(at: path + [LabelSide.sources.rawValue], identifier: "sources"),
      ]
    case let .labelNode(presenter, matrix, side):
      let key = await listen(to: matrix, for: presenter, session: session.id)
      sessions[session.id]?.labelNodes[path] = (key, side)
      let labels = labels(side, in: matrix, for: presenter, at: path)
      return labels.isEmpty ? [.node(GlowNode(.path(path)))] : labels
    case let .label(presenter, matrix, side, _):
      return labels(side, in: matrix, for: presenter, at: Array(path.dropLast()))
        .filter { $0.address == .path(path) }
    case nil:
      return []
    }
  }

  private func set(_ value: GlowValue, at path: GlowPath, session: EmberPlusSession) async -> [GlowElement] {
    guard let state = sessions[session.id] else { return [] }
    let resolved = await resolve(path)
    // a label is read only, and is answered as it is
    if case let .label(presenter, matrix, side, _)? = resolved {
      return labels(side, in: matrix, for: presenter, at: Array(path.dropLast()))
        .filter { $0.address == .path(path) }
    }
    guard case let .parameter(object, parameter)? = resolved else { return [] }
    sessions[session.id]?.setting.insert(path)
    defer { sessions[session.id]?.setting.remove(path) }
    let status = await write(value, to: parameter, of: object, as: state.controller)
    if status != .ok {
      logger.debug("\(state.controller) setting \(parameter.identifier) failed: \(status)")
    }
    // the consumer is told the value as it now is, whether or not it took
    let (element, current) = await update(parameter, of: object, at: path, as: state.controller)
    sessions[session.id]?.told[path] = current
    return [element]
  }

  private func call(
    _ invocation: GlowInvocation,
    at path: GlowPath,
    session: EmberPlusSession
  ) async -> GlowInvocationResult? {
    let id = invocation.invocationID ?? 0
    guard let state = sessions[session.id],
          case let .function(object, function)? = await resolve(path)
    else { return GlowInvocationResult(invocationID: id, success: false) }
    let arguments = invocation.arguments ?? []
    guard arguments.count == function.parameters.count else {
      return GlowInvocationResult(invocationID: id, success: false)
    }
    var parameters = [String: Any]()
    for (argument, parameter) in zip(arguments, function.parameters) {
      guard let value = parameter.type.ocp2Value(argument) else {
        return GlowInvocationResult(invocationID: id, success: false)
      }
      parameters[parameter.name] = value
    }
    let (status, answer) = await send(function.methodID, to: object, parameters, as: state.controller)
    guard status == .ok else {
      logger.debug("\(state.controller) invoking \(function.identifier) failed: \(status)")
      return GlowInvocationResult(invocationID: id, success: false)
    }
    let results = function.results.map { result in
      answer?[result.name].flatMap { result.type.glowValue(ocp2: $0) } ?? .null
    }
    return GlowInvocationResult(invocationID: id, success: true, result: results)
  }

  /// Subscribing to a stream parameter has its changes sent to the session; a
  /// subscription to anything else is as a GetDirectory has it.
  private func subscribe(to path: GlowPath, session: EmberPlusSession) async {
    switch await resolve(path) {
    case let .object(object):
      await subscribe(object, at: path, session: session.id)
    case let .parameter(object, parameter):
      if parameter.isStream { sessions[session.id]?.streams.insert(path) }
      await subscribe(object, at: Array(path.dropLast()), session: session.id)
    case let .function(object, _):
      await subscribe(object, at: Array(path.dropLast()), session: session.id)
    case .matrix, .labelNode:
      _ = await directory(path, session: session)
    case .labels, .label:
      break
    case nil:
      break
    }
  }

  /// A subscription to all of an object's property changes, which the device sends the
  /// session's controller.
  private static func subscription(_ objectNumber: OcaONo) -> OcaSubscriptionManagerSubscription {
    .subscription2(OcaSubscription2(
      event: OcaEvent(emitterONo: objectNumber, eventID: OcaPropertyChangedEventID),
      notificationDeliveryMode: .normal,
      destinationInformation: OcaNetworkAddress()
    ))
  }

  private func subscribe(_ object: SwiftOCADevice.OcaRoot, at path: GlowPath, session id: UInt64) async {
    guard let state = sessions[id], state.subscribed[object.objectNumber] == nil else { return }
    sessions[id]?.subscribed[object.objectNumber] = path
    await hear(object.objectNumber, session: id)
  }

  /// Has the device send the session's controller the object's property changes.
  private func hear(_ objectNumber: OcaONo, session id: UInt64) async {
    guard let state = sessions[id], sessions[id]?.hearing.insert(objectNumber).inserted == true
    else { return }
    do {
      try await device.subscriptionManager?.addSubscription(
        Self.subscription(objectNumber),
        for: state.controller
      )
    } catch {
      logger.debug("\(state.controller) cannot hear of \(objectNumber): \(error)")
    }
  }

  /// Unsubscribing from a stream parameter stops its stream. Unsubscribing from a node
  /// drops every subscription below it, streams included.
  private func unsubscribe(from path: GlowPath, session: EmberPlusSession) async {
    guard let state = sessions[session.id] else { return }
    sessions[session.id]?.streams = state.streams.filter { !$0.starts(with: path) }
    if case .parameter? = await resolve(path) { return }
    for (objectNumber, objectPath) in state.subscribed where objectPath.starts(with: path) {
      sessions[session.id]?.subscribed[objectNumber] = nil
    }
    sessions[session.id]?.matrices = state.matrices.filter { !$0.key.starts(with: path) }
    sessions[session.id]?.labelNodes = state.labelNodes.filter { !$0.key.starts(with: path) }
    sessions[session.id]?.toldConnections = state.toldConnections
      .filter { !$0.key.starts(with: path) }
    // what the session no longer hears of in any way, the device stops sending it
    guard let remaining = sessions[session.id] else { return }
    for objectNumber in remaining.hearing where !remaining.hears(objectNumber) {
      await device.subscriptionManager?.removeSubscription(
        Self.subscription(objectNumber),
        for: state.controller
      )
      sessions[session.id]?.hearing.remove(objectNumber)
    }
    sessions[session.id]?.told = state.told.filter { !$0.key.starts(with: path) }
  }

  // MARK: - Matrices

  /// The identifier of an object's node, as its parent presents it.
  private func identifier(of object: SwiftOCADevice.OcaRoot, at path: GlowPath) async -> String {
    guard path.count > 1, case let .object(parent)? = await resolve(Array(path.dropLast())) else {
      return rootIdentifier
    }
    let members = await members(of: parent)
    return identifiers(of: members, beside: presentation(of: parent))[path.last!] ?? object.role
  }

  /// A matrix's identifier: its own, else for the object's own matrix the object's.
  private func matrixIdentifier(_ matrix: EmberPlusOcaMatrix, objectIdentifier: String) -> String {
    matrix.identifier ?? matrix.number.map { "matrix\($0)" } ?? objectIdentifier
  }

  private func matrixContents(
    _ matrix: EmberPlusOcaMatrix,
    for presenter: Presenter,
    at path: GlowPath,
    identifier: String,
    signals: EmberPlusOcaSignals
  ) -> GlowMatrixContents {
    let role = presenter.role
    return GlowMatrixContents(
      identifier: identifier,
      description: matrix.description ?? (matrix.number == nil && !role.isEmpty ? role : nil),
      type: matrix.type,
      addressingMode: matrix.addressingMode,
      targetCount: Int32(clamping: signals.targets.count),
      sourceCount: Int32(clamping: signals.sources.count),
      labels: matrix.labels
        .map { [GlowLabel(basePath: path + [Self.labelsNumber], description: $0)] }
    )
  }

  /// An object's matrices, as its directory lists them: its own in full, the others by
  /// their contents.
  private func matrices(
    for presenter: Presenter,
    at path: GlowPath,
    session id: UInt64
  ) async -> [GlowElement] {
    var elements = [GlowElement]()
    for matrix in presenter.emberPlusMatrices {
      guard let number = matrix.number else {
        let objectIdentifier = await identifier(of: presenter, at: path)
        let identifier = matrixIdentifier(matrix, objectIdentifier: objectIdentifier)
        await elements.append(self.matrix(
          matrix,
          for: presenter,
          at: path,
          identifier: identifier,
          session: id
        ))
        if matrix.labels != nil {
          elements.append(labelNode(at: path + [Self.labelsNumber], identifier: "labels"))
        }
        continue
      }
      guard Self.isMatrixNumber(number) else {
        logger
          .warning(
            "not presenting matrix \(number) of \(presenter.objectNumber): its number is not 1 to 255"
          )
        continue
      }
      elements.append(.matrix(GlowMatrix(.path(path + [number]), contents: matrixContents(
        matrix,
        for: presenter,
        at: path + [number],
        identifier: matrixIdentifier(matrix, objectIdentifier: ""),
        signals: presenter.emberPlusSignals(for: matrix)
      ))))
    }
    return elements
  }

  /// Has the session hear of the objects whose changes may change the matrix.
  private func listen(
    to matrix: EmberPlusOcaMatrix,
    for presenter: Presenter,
    session id: UInt64
  ) async -> MatrixKey {
    let emitters = presenter.emberPlusEmitters(for: matrix)
    for emitter in emitters {
      await hear(emitter, session: id)
    }
    return MatrixKey(
      objectNumber: presenter.objectNumber,
      number: matrix.number,
      emitters: Set(emitters)
    )
  }

  /// The presenter and matrix a session's key names, as they now are.
  private func matrix(for key: MatrixKey) async -> (Presenter, EmberPlusOcaMatrix)? {
    guard let presenter = await device.objects[key.objectNumber] as? Presenter,
          let matrix = presenter.emberPlusMatrices.first(where: { $0.number == key.number })
    else { return nil }
    return (presenter, matrix)
  }

  /// The matrix at a path: a numbered matrix, or an object's own.
  private func matrix(at path: GlowPath) async -> (Presenter, EmberPlusOcaMatrix)? {
    switch await resolve(path) {
    case let .matrix(presenter, matrix):
      return (presenter, matrix)
    case let .object(object):
      guard let presenter = object as? Presenter,
            let own = presenter.emberPlusMatrices.first(where: { $0.number == nil })
      else { return nil }
      return (presenter, own)
    default:
      return nil
    }
  }

  /// A matrix with its signals and connections, as its GetDirectory answers, which has
  /// the session hear of its changes from then on.
  private func matrix(
    _ matrix: EmberPlusOcaMatrix,
    for presenter: Presenter,
    at path: GlowPath,
    identifier: String,
    session id: UInt64
  ) async -> GlowElement {
    guard let state = sessions[id] else { return .matrix(GlowMatrix(.path(path))) }
    let key = await listen(to: matrix, for: presenter, session: id)
    sessions[id]?.matrices[path] = key
    let signals = presenter.emberPlusSignals(for: matrix)
    let current = await presenter.emberPlusConnections(for: matrix, controller: state.controller)
    var told = [Int32: [Int32]]()
    let connections = signals.targets.map { target in
      let sources = current[target.number] ?? []
      told[target.number] = sources
      return GlowConnection(target: target.number, sources: Self.glowSources(sources))
    }
    sessions[id]?.toldConnections[path] = told
    return .matrix(GlowMatrix(
      .path(path),
      contents: matrixContents(
        matrix,
        for: presenter,
        at: path,
        identifier: identifier,
        signals: signals
      ),
      targets: signals.targets.map(\.number),
      sources: signals.sources.map(\.number),
      connections: connections
    ))
  }

  private static func glowSources(_ sources: [Int32]) -> [UInt32] {
    sources.compactMap { UInt32(exactly: $0) }
  }

  private func labelNode(at path: GlowPath, identifier: String) -> GlowElement {
    .node(GlowNode(.path(path), contents: GlowNodeContents(identifier: identifier, isOnline: true)))
  }

  /// A label node's parameters: one string per signal, numbered by the signal's number.
  private func labels(
    _ side: LabelSide,
    in matrix: EmberPlusOcaMatrix,
    for presenter: Presenter,
    at path: GlowPath
  ) -> [GlowElement] {
    let signals = presenter.emberPlusSignals(for: matrix)
    let prefix = side == .targets ? "t" : "s"
    return (side == .targets ? signals.targets : signals.sources).compactMap { signal in
      guard let number = UInt32(exactly: signal.number) else { return nil }
      return .parameter(GlowParameter(.path(path + [number]), contents: GlowParameterContents(
        identifier: "\(prefix)\(signal.number)",
        value: .string(signal.label ?? ""),
        access: .read,
        isOnline: true,
        type: .string
      )))
    }
  }

  /// Applies a consumer's connection request to the matrix as one change, through the
  /// presenter as the session's controller. Each target asked about is answered as it now
  /// is: modified, or locked with its sources unchanged if the request was refused.
  private func change(
    _ connections: [GlowConnection],
    of path: GlowPath,
    session: EmberPlusSession
  ) async -> [GlowElement] {
    guard let state = sessions[session.id],
          let (presenter, matrix) = await matrix(at: path) else { return [] }
    let signals = presenter.emberPlusSignals(for: matrix)
    let targets = Set(signals.targets.map(\.number))
    let sources = Set(signals.sources.map(\.number))
    var asked = [Int32]()
    var changes = [EmberPlusOcaConnectionChange]()
    for connection in connections where targets.contains(connection.target) {
      if !asked.contains(connection.target) { asked.append(connection.target) }
      changes.append(EmberPlusOcaConnectionChange(
        target: connection.target,
        sources: (connection.sources ?? []).compactMap { Int32(exactly: $0) }
          .filter(sources.contains),
        operation: connection.operation ?? .absolute
      ))
    }
    guard !changes.isEmpty else { return [] }
    sessions[session.id]?.connecting.insert(path)
    defer { sessions[session.id]?.connecting.remove(path) }
    var disposition = GlowConnectionDisposition.modified
    var after = [Int32: [Int32]]()
    do {
      after = try await presenter.emberPlusConnect(
        changes,
        matrix: matrix,
        controller: state.controller
      )
    } catch {
      logger.debug("\(state.controller) connecting \(changes) refused: \(error)")
      disposition = .locked
    }
    if asked.contains(where: { after[$0] == nil }) {
      let current = await presenter.emberPlusConnections(for: matrix, controller: state.controller)
      after.merge(current) { answered, _ in answered }
    }
    let answers = asked.map { target in
      let sources = after[target] ?? []
      sessions[session.id]?.toldConnections[path, default: [:]][target] = sources
      return GlowConnection(
        target: target,
        sources: Self.glowSources(sources),
        disposition: disposition
      )
    }
    return [.matrix(GlowMatrix(.path(path), connections: answers))]
  }

  /// A matrix's connections changed: the targets whose sources the session was told
  /// otherwise, as tallies.
  private func tally(
    _ matrix: EmberPlusOcaMatrix,
    for presenter: Presenter,
    at path: GlowPath,
    session id: UInt64
  ) async {
    guard let state = sessions[id] else { return }
    let current = await presenter.emberPlusConnections(for: matrix, controller: state.controller)
    // a change of the session's own is answered by its reply
    guard sessions[id]?.connecting.contains(path) != true else { return }
    var changed = [GlowConnection]()
    for target in presenter.emberPlusSignals(for: matrix).targets {
      let sources = current[target.number] ?? []
      guard sessions[id]?.toldConnections[path]?[target.number] != sources else { continue }
      sessions[id]?.toldConnections[path, default: [:]][target.number] = sources
      changed.append(GlowConnection(target: target.number, sources: Self.glowSources(sources)))
    }
    if !changed.isEmpty {
      state.session.send(.elements([.matrix(GlowMatrix(.path(path), connections: changed))]))
    }
  }

  /// A matrix's signals changed: the matrix again in full, and the label nodes the
  /// session has.
  private func resendSignals(
    _ matrix: EmberPlusOcaMatrix,
    for presenter: Presenter,
    at path: GlowPath,
    session id: UInt64
  ) async {
    guard let state = sessions[id] else { return }
    let identifier = await matrix.number == nil
      ? matrixIdentifier(matrix, objectIdentifier: identifier(of: presenter, at: path))
      : matrixIdentifier(matrix, objectIdentifier: "")
    var elements = await [self.matrix(
      matrix,
      for: presenter,
      at: path,
      identifier: identifier,
      session: id
    )]
    for (labelPath, label) in state.labelNodes
      where label.matrix.objectNumber == presenter.objectNumber && label.matrix.number == matrix
      .number
    {
      elements += labels(label.side, in: matrix, for: presenter, at: labelPath)
    }
    state.session.send(.elements(elements))
  }

  /// An object's property changed: whatever the session knows of the matrices that
  /// listen to it.
  private func matrixChanged(
    _ property: OcaPropertyID,
    for objectNumber: OcaONo,
    session id: UInt64
  ) async {
    guard let state = sessions[id] else { return }
    var resent = Set<GlowPath>()
    for (path, key) in state.matrices where key.emitters.contains(objectNumber) {
      guard let (presenter, matrix) = await matrix(for: key) else { continue }
      if presenter.emberPlusSignalProperties.contains(property) {
        resent.insert(path)
        await resendSignals(matrix, for: presenter, at: path, session: id)
      } else if presenter.emberPlusConnectionProperties.contains(property),
                sessions[id]?.connecting.contains(path) != true
      {
        await tally(matrix, for: presenter, at: path, session: id)
      }
    }
    // label nodes of a matrix the session has not the directory of
    var labels = [GlowElement]()
    for (path, label) in state.labelNodes where label.matrix.emitters.contains(objectNumber) {
      guard let (presenter, matrix) = await matrix(for: label.matrix),
            presenter.emberPlusSignalProperties.contains(property),
            !resent.contains(where: { path.starts(with: $0) }) else { continue }
      labels += self.labels(label.side, in: matrix, for: presenter, at: path)
    }
    if !labels.isEmpty {
      state.session.send(.elements(labels))
    }
  }

  // MARK: - Changes

  /// The device told a session's controller that one of an object's properties changed.
  private func changed(_ property: OcaPropertyID, of objectNumber: OcaONo, session id: UInt64) async {
    guard let state = sessions[id], let object = await device.objects[objectNumber] else { return }

    await matrixChanged(property, for: objectNumber, session: id)

    guard let path = state.subscribed[objectNumber] else { return }

    // a block's members changed: its directory, as it now is, shows the new ones
    if property == OcaPropertyID("3.2"), object is any OcaBlockContainer {
      state.session.send(.elements(await directory(path, session: state.session)))
      return
    }

    var changes = [GlowElement]()
    var streams = [GlowStreamEntry]()
    for parameter in presentation(of: object).parameters(for: property) {
      let parameterPath = path + [parameter.number]
      if parameter.isStream {
        // only to a session that subscribed to it, and in a stream collection
        guard sessions[id]?.streams.contains(parameterPath) == true else { continue }
        let (value, _, _) = await read(parameter, of: object, as: state.controller)
        guard let value, sessions[id]?.told[parameterPath] != value else { continue }
        sessions[id]?.told[parameterPath] = value
        streams.append(GlowStreamEntry(
          streamIdentifier: streamIdentifier(of: parameter, of: object),
          value: value
        ))
        continue
      }
      // a set of the session's own is answered by its reply, before or after this read
      guard sessions[id]?.setting.contains(parameterPath) != true else { continue }
      let (element, value) = await update(parameter, of: object, at: parameterPath, as: state.controller)
      guard let value, sessions[id]?.setting.contains(parameterPath) != true,
            sessions[id]?.told[parameterPath] != value else { continue }
      sessions[id]?.told[parameterPath] = value
      changes.append(element)
    }
    if !changes.isEmpty {
      state.session.send(.elements(changes))
    }
    if !streams.isEmpty {
      state.session.send(.streams(streams))
    }
  }
}
