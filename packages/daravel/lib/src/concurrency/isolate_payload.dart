import 'dart:isolate';
import 'dart:typed_data';

/// A value prepared to cross an isolate boundary cheaply (ADR-031).
///
/// Text crosses as a `String`, which the VM shares between the isolates of
/// a group instead of copying, whatever its size: JSON belongs here, never
/// in bytes. Binary data (a PDF, an image, a compressed body) below
/// [transferThreshold] crosses as the `Uint8List` itself, which `send`
/// copies; from the threshold on it crosses as a `TransferableTypedData`,
/// copied once into a buffer that then moves to the receiver without a
/// second copy.
///
/// A transferable can be received by one isolate only, so a payload sent to
/// many ports (a broadcast) stays a `String`.
///
/// ```dart
/// // Sending isolate
/// reply.send(IsolatePayload.bytes(pdf).toWire());
/// // Receiving port's handler
/// final pdf = IsolatePayload.fromWire(message! as Object) as Uint8List;
/// ```
sealed class IsolatePayload {
  const IsolatePayload._();

  /// Text: shared between isolates by the VM, never copied.
  const factory IsolatePayload.text(String text) = TextPayload;

  /// Bytes: below [transferThreshold] sent as they are; from it on moved as
  /// a `TransferableTypedData`.
  const factory IsolatePayload.bytes(Uint8List bytes) = BytesPayload;

  /// The size from which bytes cross as a `TransferableTypedData`. Below it
  /// a plain copy is cheaper than making and materializing a transferable.
  static const int transferThreshold = 32 * 1024;

  /// What to put in `SendPort.send`: a `String`, a `Uint8List` or a
  /// `TransferableTypedData`. Each call makes a new wire form.
  Object toWire();

  /// The value a wire form from [toWire] stands for: a `String` or a
  /// `Uint8List`. A `TransferableTypedData` is materialized here, which can
  /// happen exactly once, so call this in the receiving port's handler only;
  /// a second call with the same transferable throws.
  static Object fromWire(Object wire) => switch (wire) {
    String() || Uint8List() => wire,
    TransferableTypedData() => wire.materialize().asUint8List(),
    _ => throw ArgumentError.value(
      wire,
      'wire',
      'Not the wire form of an IsolatePayload',
    ),
  };
}

/// An [IsolatePayload] of text.
final class TextPayload extends IsolatePayload {
  /// [text], to send.
  const TextPayload(this.text) : super._();

  /// The text.
  final String text;

  @override
  Object toWire() => text;
}

/// An [IsolatePayload] of binary data.
final class BytesPayload extends IsolatePayload {
  /// [bytes], to send. They are read when [toWire] is called.
  const BytesPayload(this.bytes) : super._();

  /// The bytes.
  final Uint8List bytes;

  /// Whether [toWire] makes a `TransferableTypedData`.
  bool get transfers => bytes.length >= IsolatePayload.transferThreshold;

  @override
  Object toWire() =>
      transfers ? TransferableTypedData.fromList([bytes]) : bytes;
}
