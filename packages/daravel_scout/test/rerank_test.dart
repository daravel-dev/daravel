import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:daravel_scout/src/rerank.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';

final class Doc extends Model {
  static final ModelDefinition<Doc> definition = ModelDefinition<Doc>(
    table: 'docs',
    factory: Doc.new,
    timestamps: false,
  );

  @override
  ModelDefinition<Doc> get modelDefinition => definition;
}

Doc doc(int id, Object? embedding) =>
    Doc.definition.hydrate({'id': id, 'embedding': embedding});

Float32List random(Random r, int length) => Float32List.fromList([
  for (var i = 0; i < length; i++) r.nextDouble() * 2 - 1,
]);

/// How far [cosineF32x4] (float32 lane sums) may be from [cosineScalar]
/// (double sums): float32 keeps about 7 significant digits, and summing
/// 3 072 products in 768 lanes loses a few more. The README and the dartdoc
/// state the same bound.
const double float32Tolerance = 1e-5;

void main() {
  const dimensions = [1, 3, 4, 5, 1536, 3072];

  group('cosineF32x4 equals the scalar cosine', () {
    final r = Random(42);
    for (final length in dimensions) {
      test('random vectors of $length dimensions', () {
        for (var round = 0; round < 20; round++) {
          final a = random(r, length);
          final b = random(r, length);
          expect(
            cosineF32x4(a, b),
            closeTo(cosineScalar(a, b), float32Tolerance),
          );
        }
      });

      test('edge vectors of $length dimensions', () {
        final a = random(r, length);
        final negated = Float32List.fromList([for (final x in a) -x]);
        final scaled = Float32List.fromList([for (final x in a) x * 1000]);
        final zero = Float32List(length);
        expect(cosineF32x4(a, a), closeTo(1, float32Tolerance));
        expect(cosineF32x4(a, scaled), closeTo(1, float32Tolerance));
        expect(cosineF32x4(a, negated), closeTo(-1, float32Tolerance));
        expect(cosineF32x4(a, zero), 0);
        expect(cosineF32x4(zero, zero), 0);
        expect(cosineScalar(a, zero), 0);
        expect(cosineF32x4(a, a), lessThanOrEqualTo(1));
        // Only the last lane is set: the remainder path when length % 4 != 0.
        final last = Float32List(length)..[length - 1] = 1;
        expect(cosineF32x4(last, last), closeTo(1, 1e-6));
        expect(cosineF32x4(last, a), closeTo(cosineScalar(last, a), 1e-6));
      });
    }

    test('an unaligned view goes through the scalar path', () {
      final backing = random(r, 1537);
      final a = Float32List.sublistView(backing, 1);
      final b = random(r, 1536);
      expect(a.offsetInBytes % 16, isNot(0));
      expect(cosineF32x4(a, b), closeTo(cosineScalar(a, b), 1e-9));
    });

    test('different dimensions are refused', () {
      expect(
        () => cosineF32x4(Float32List(4), Float32List(5)),
        throwsArgumentError,
      );
    });
  });

  group('rerankByCosine', () {
    test('orders by similarity, ties and missing vectors in given order', () {
      final candidates = [
        doc(1, [0.0, 1.0, 0.0]), // orthogonal: 0
        doc(2, null), // no vector: last
        doc(3, '[1, 0, 0]'), // pgvector text: 1
        doc(4, [-1.0, 0.0, 0.0]), // opposite: -1
        doc(5, [2.0, 0.0, 0.0]), // same direction: 1, after 3
        doc(6, [1.0, 1.0, 0.0]), // 0.707
      ];
      final ranked = rerankByCosine(candidates, const [1, 0, 0], 'embedding');
      expect([for (final m in ranked) m.key], [3, 5, 6, 1, 4, 2]);
    });

    test("reads pgvector's binary and text forms", () {
      final binary = ByteData(4 + 3 * 4)
        ..setUint16(0, 3)
        ..setFloat32(4, 0.25)
        ..setFloat32(8, -1.5)
        ..setFloat32(12, 2);
      pg.UndecodedBytes undecoded(List<int> bytes, {required bool binary}) =>
          pg.UndecodedBytes(
            typeOid: 99999,
            isBinary: binary,
            bytes: Uint8List.fromList(bytes),
            encoding: utf8,
          );
      expect(vectorOf(undecoded(binary.buffer.asUint8List(), binary: true)), [
        0.25,
        -1.5,
        2,
      ]);
      expect(vectorOf(undecoded(utf8.encode('[0.25,-1.5,2]'), binary: false)), [
        0.25,
        -1.5,
        2,
      ]);
      expect(vectorOf(null), isNull);
    });

    test('reads MariaDB little-endian float32 bytes', () {
      final bytes = ByteData(8)
        ..setFloat32(0, 0.5, Endian.little)
        ..setFloat32(4, 0.5, Endian.little);
      final ranked = rerankByCosine(
        [
          doc(1, [1.0, -1.0]),
          doc(2, bytes.buffer.asUint8List()),
        ],
        const [1, 1],
        'embedding',
      );
      expect([for (final m in ranked) m.key], [2, 1]);
      expect(vectorOf(bytes.buffer.asUint8List()), [0.5, 0.5]);
    });

    test('1 000 candidates of 1 536 dimensions match the scalar order', () {
      final r = Random(7);
      final query = random(r, 1536);
      final candidates = [
        for (var id = 0; id < 1000; id++) doc(id, random(r, 1536).toList()),
      ];
      final expected = [...candidates]
        ..sort((a, b) {
          double score(Doc d) => cosineScalar(
            query,
            Float32List.fromList(d.attributes['embedding']! as List<double>),
          );
          return score(b).compareTo(score(a));
        });
      final ranked = rerankByCosine(candidates, query, 'embedding');
      // Float32 lanes may swap two near-equal scores; compare the scores.
      for (var i = 0; i < ranked.length; i++) {
        final got = cosineScalar(query, vectorOf(ranked[i]['embedding'])!);
        final want = cosineScalar(query, vectorOf(expected[i]['embedding'])!);
        expect(got, closeTo(want, float32Tolerance));
      }
    });
  });
}
