# SwiftEmberPlus

An [Ember+](https://github.com/Lawo/ember-plus) provider in Swift, and a bridge that
presents a [SwiftOCA](https://github.com/PADL/SwiftOCA) device through it.

- **`EmberPlus`** knows nothing of OCA. It has S101 framing (both variants, with
  multi-packet messages and keep-alives), the Glow DTD 2.50 over BER (decoding indefinite
  lengths, using [swift-asn1](https://github.com/apple/swift-asn1)), and a TCP provider
  that passes each consumer's requests to an `EmberPlusTreeSource`. `EmberPlusConsumer` is
  the other end, for tools and tests.
- **`EmberPlusOCABridge`** is an `EmberPlusTreeSource` over a SwiftOCADevice device. Each
  Ember+ session is a controller of its own to the device, so locks and access checks
  apply as for any OCA controller, and nothing of the tree is kept: each request is
  answered from the device as it is now.

## The OCA tree in Ember+

- The root block is node 1. Under an object's node are its properties as parameters,
  numbered `defLevel << 8 | index` (OcaGain's Gain, 4.1, is 1025), and its methods as
  functions, numbered `0x800 | defLevel << 8 | index`. Under a block are its members,
  numbered by object number, and under the root block, the managers.
- Ember+ numbers are 32-bit signed integers, so a member's number is its object number
  without the top bit, or `0x7000_0000` with the low 24 bits where that would clash; a
  number need only be unique among its siblings.
- A property's accessors are not functions. A getter that is a property's in all but
  declaration (`GetRole`, OcaLevelSensor's `GetReading`) is a parameter, writable if the
  class has the matching setter. Properties of structured types, and OcaRoot's lock
  methods, are not presented.
- Asking for a node's directory subscribes the session to its object's property changes,
  as Ember+ has it. A sensor's reading is a stream: a consumer subscribes to it, and its
  changes come in stream collections.
- An object that conforms to `EmberPlusOcaMatrixRepresentable` presents crosspoint
  matrices: under its node (numbered 1 to 255), or as its node. It gives each matrix's
  type and addressing, its targets and sources with their signal numbers and labels, each
  target's sources, and the properties whose changes mean the connections or the signals
  changed. A consumer's connection request is applied as one call, as the session's
  controller, and answered `modified`, or `locked` with the sources as they now are if the
  object refused it; later changes are tallies of the targets that changed, and a change
  of signals sends the matrix again. Labels are a node under the matrix (Ember+ 1.1:
  `targets` 1, `sources` 2, a string parameter per signal).
- A matrix of boolean actuators conforms: the actuator at (x, y) connects source y to
  target x.
- The provider is advertised over DNS-SD as `_ember._tcp`, named for the device.

## Example

`Examples/EmberPlusDevice` is SwiftOCA's OCADevice example served over Ember+: a block of
boolean actuators in a matrix and a gain whose changes a counter notifier counts, with a
channel strip of a gain, a mute and a moving level meter. It prints what consumers
change, and serves OCP.1 and OCP.2 alongside, so a change can be made from either side.

    swift run EmberPlusDevice [--port 9000] [--oca-port 65000] [--no-meter] [--debug]

`Examples/EmberPlusProbe` is a Glow consumer: it walks a provider's tree, reads a matrix
with its labels and connections, sends connect, disconnect and absolute requests and
prints each target's disposition, and prints the tallies that follow. A path is dotted
numbers or identifiers separated by slashes; signals are numbers or labels.

    swift run EmberPlusProbe <host>[:<port>] tree [<path>] [<depth>]
    swift run EmberPlusProbe <host>[:<port>] matrix <path>
    swift run EmberPlusProbe <host>[:<port>] connect|disconnect|absolute <path> <target> [<source>...]
    swift run EmberPlusProbe <host>[:<port>] watch <path> [<seconds>]

## Compatibility

Ember+'s REAL encoding is not X.690's: libember, EmberLib.net and libember_slim all
place the binary point after the mantissa's leading one, and Lawo has kept that for
compatibility with deployed devices. SwiftEmberPlus encodes and decodes REALs as they
do. The tests check encodings against vectors produced with libember and libs101.

## Licence

Apache 2.0, with portions derived from Lawo's Ember+ under the Boost Software License:
see [LICENSE.md](LICENSE.md).
