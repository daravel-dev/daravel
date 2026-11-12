import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:postgres/postgres.dart' as pg;

/// The cosine similarity of [a] and [b], four lanes at a time with
/// `Float32x4`; the lanes past the last multiple of four, and a list whose
/// view is not 16-byte aligned, go through [cosineScalar]. A zero vector is
/// alike to nothing: 0.
///
/// The lanes sum in float32 (what `Float32x4` holds), [cosineScalar] in
/// doubles, so the two differ by up to about 1e-5 for 3 072 dimensions:
/// two models whose scores are that close may be ordered differently by
/// either path. The rerank reads vectors aligned ([vectorOf]), so it always
/// takes this one.
///
/// Internal to `hybrid(rerank: true)`: not exported.
double cosineF32x4(Float32List a, Float32List b) {
  final length = _sameLength(a, b);
  if (a.offsetInBytes % 16 != 0 || b.offsetInBytes % 16 != 0) {
    return cosineScalar(a, b);
  }
  final lanes = length >> 2;
  final va = Float32x4List.view(a.buffer, a.offsetInBytes, lanes);
  final vb = Float32x4List.view(b.buffer, b.offsetInBytes, lanes);
  var dot = Float32x4.zero();
  var normA = Float32x4.zero();
  var normB = Float32x4.zero();
  for (var i = 0; i < lanes; i++) {
    final x = va[i];
    final y = vb[i];
    dot += x * y;
    normA += x * x;
    normB += y * y;
  }
  var d = dot.x + dot.y + dot.z + dot.w;
  var na = normA.x + normA.y + normA.z + normA.w;
  var nb = normB.x + normB.y + normB.z + normB.w;
  for (var i = lanes << 2; i < length; i++) {
    final x = a[i];
    final y = b[i];
    d += x * y;
    na += x * x;
    nb += y * y;
  }
  return _cosine(d, na, nb);
}

/// [cosineF32x4] one float at a time, in doubles: the fallback and the
/// reference the SIMD path is tested and benchmarked against.
double cosineScalar(Float32List a, Float32List b) {
  final length = _sameLength(a, b);
  var d = 0.0;
  var na = 0.0;
  var nb = 0.0;
  for (var i = 0; i < length; i++) {
    final x = a[i];
    final y = b[i];
    d += x * y;
    na += x * x;
    nb += y * y;
  }
  return _cosine(d, na, nb);
}

int _sameLength(Float32List a, Float32List b) {
  if (a.length != b.length) {
    throw ArgumentError(
      'Vectors of ${a.length} and ${b.length} dimensions cannot be compared.',
    );
  }
  return a.length;
}

double _cosine(double dot, double normA, double normB) {
  if (normA == 0 || normB == 0) {
    return 0;
  }
  return (dot / math.sqrt(normA * normB)).clamp(-1.0, 1.0);
}

/// [candidates] most alike to [query] first, by [cosineF32x4] on each
/// model's [column]; equal scores keep their order, and models without a
/// vector in [column] (not selected, or null) follow in their order.
///
/// Throws [ArgumentError] when a candidate's vector has other dimensions than
/// [query].
List<M> rerankByCosine<M extends Model>(
  List<M> candidates,
  List<num> query,
  String column,
) {
  final target = Float32List.fromList([for (final n in query) n.toDouble()]);
  final scored = <(int, double)>[];
  final missing = <int>[];
  for (var i = 0; i < candidates.length; i++) {
    final vector = vectorOf(candidates[i].attributes[column]);
    if (vector == null) {
      missing.add(i);
    } else {
      scored.add((i, cosineF32x4(target, vector)));
    }
  }
  scored.sort((a, b) {
    final byScore = b.$2.compareTo(a.$2);
    return byScore != 0 ? byScore : a.$1.compareTo(b.$1);
  });
  return [
    for (final (i, _) in scored) candidates[i],
    for (final i in missing) candidates[i],
  ];
}

/// A stored vector as a 16-byte aligned [Float32List], read straight from the
/// driver's value where its form is known (MariaDB's little-endian float32
/// bytes, pgvector's binary or text form, a list of numbers); null for a
/// missing one.
Float32List? vectorOf(Object? raw) {
  switch (raw) {
    case null:
      return null;
    case final Float32List floats when floats.offsetInBytes % 16 == 0:
      return floats;
    case final Uint8List bytes:
      final floats = Float32List(bytes.lengthInBytes ~/ 4);
      if (Endian.host == Endian.little) {
        floats.buffer.asUint8List().setRange(0, floats.lengthInBytes, bytes);
        return floats;
      }
      final data = ByteData.sublistView(bytes);
      for (var i = 0; i < floats.length; i++) {
        floats[i] = data.getFloat32(i * 4, Endian.little);
      }
      return floats;
    // pgvector's binary form: dimensions, a reserved field, then big-endian
    // floats. VectorCast would also round each to its shortest decimal.
    case final pg.UndecodedBytes raw when raw.isBinary:
      final data = ByteData.sublistView(raw.bytes);
      final floats = Float32List(data.getUint16(0));
      for (var i = 0; i < floats.length; i++) {
        floats[i] = data.getFloat32(4 + i * 4);
      }
      return floats;
    case final pg.UndecodedBytes raw:
      return vectorOf(raw.asString);
    case final String text:
      return vectorOf(jsonDecode(text));
    case final List<double> values:
      return Float32List.fromList(values);
    case final List<Object?> values:
      return Float32List.fromList([
        for (final value in values) (value! as num).toDouble(),
      ]);
    default:
      // Anything else VectorCast reads, or its error.
      return vectorOf(const VectorCast().get(raw));
  }
}
