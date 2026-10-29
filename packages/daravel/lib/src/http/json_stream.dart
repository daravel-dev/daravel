import 'dart:convert';

import 'response.dart';

/// The bytes of a JSON array of [items], written as the items arrive:
/// `[` and `]` around them, a comma between, each item encoded with
/// [Response.encodeJson] (or [Response.encodePhpJson] with
/// [phpCompatible]) as soon as it is produced, so a response never holds
/// every row at once. With [wrap], the array is the value of that key in
/// an object: `{"data":[...]}`, as Laravel's `response()->streamJson()`
/// writes.
///
/// Bytes go out in chunks of about [flushBytes] (64 KiB), a balance between
/// socket writes and memory; the last chunk may be smaller. The result is
/// byte for byte what [Response.json] writes for the collected list.
Stream<List<int>> jsonArrayBytes(
  Stream<Object?> items, {
  bool phpCompatible = false,
  String? wrap,
  int flushBytes = 64 * 1024,
}) async* {
  final encode = phpCompatible ? Response.encodePhpJson : Response.encodeJson;
  final buffer = StringBuffer();
  if (wrap != null) {
    buffer
      ..write('{')
      ..write(encode(wrap))
      ..write(':');
  }
  buffer.write('[');
  var first = true;
  await for (final item in items) {
    if (!first) {
      buffer.write(',');
    }
    first = false;
    buffer.write(encode(item));
    if (buffer.length >= flushBytes) {
      yield utf8.encode(buffer.toString());
      buffer.clear();
    }
  }
  buffer.write(']');
  if (wrap != null) {
    buffer.write('}');
  }
  yield utf8.encode(buffer.toString());
}
