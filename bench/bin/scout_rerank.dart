// What `hybrid(rerank: true)` costs in `daravel_scout` (ADR-032 T6).
//
// ```bash
// dart run bin/scout_rerank.dart                 # JIT
// dart build cli -t bin/scout_rerank.dart -o build/scout_rerank
// build/scout_rerank/bundle/bin/scout_rerank      # AOT (.exe on Windows)
// ```
//
// Scores 1 000 candidates against one query vector of 1 536 and 3 072
// dimensions, with the scalar cosine and with the `Float32x4` one, and prints
// the time per rerank (1 000 cosines) with the time per cosine. Then the
// whole `rerankByCosine` on 1 000 models whose vectors are as a driver
// returns them (MariaDB's float32 bytes, pgvector's binary and text forms),
// which adds reading them into `Float32List`s.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
// The cosine is internal to daravel_scout: no public API for one benchmark.
// ignore: implementation_imports
import 'package:daravel_scout/src/rerank.dart';
import 'package:postgres/postgres.dart' as pg;

final class _Doc extends Model {
  static final ModelDefinition<_Doc> definition = ModelDefinition<_Doc>(
    table: 'docs',
    factory: _Doc.new,
    timestamps: false,
  );

  @override
  ModelDefinition<_Doc> get modelDefinition => definition;
}

const _candidates = 1000;

Float32List _random(Random r, int length) => Float32List.fromList([
  for (var i = 0; i < length; i++) r.nextDouble() * 2 - 1,
]);

/// The shortest decimal that is this float4, as pgvector prints it.
String _shortest(double value) {
  final float = Float32List(1);
  for (var digits = 1; digits < 9; digits++) {
    final text = value.toStringAsPrecision(digits);
    float[0] = double.parse(text);
    if (float[0] == value) {
      return text;
    }
  }
  return value.toStringAsPrecision(9);
}

pg.UndecodedBytes _undecoded(List<int> bytes, {required bool binary}) =>
    pg.UndecodedBytes(
      typeOid: 99999,
      isBinary: binary,
      bytes: Uint8List.fromList(bytes),
      encoding: utf8,
    );

/// Mean microseconds of one call of [run], after a warm-up.
double _time(void Function() run, {int warmUp = 20, int rounds = 200}) {
  for (var i = 0; i < warmUp; i++) {
    run();
  }
  final watch = Stopwatch()..start();
  for (var i = 0; i < rounds; i++) {
    run();
  }
  return watch.elapsedMicroseconds / rounds;
}

void main() {
  final r = Random(1);
  var sink = 0.0;
  print(
    '| Dimensions | Scalar | Float32x4 | Speed-up | Rerank, MariaDB bytes '
    '| Rerank, pgvector binary | Rerank, pgvector text |',
  );
  print('| --: | --: | --: | --: | --: | --: | --: |');
  for (final dimensions in const [1536, 3072]) {
    final query = _random(r, dimensions);
    final vectors = [
      for (var i = 0; i < _candidates; i++) _random(r, dimensions),
    ];
    double rerank(double Function(Float32List, Float32List) cosine) {
      var best = -1.0;
      for (final vector in vectors) {
        best = max(best, cosine(query, vector));
      }
      return best;
    }

    final scalar = _time(() => sink += rerank(cosineScalar));
    final simd = _time(() => sink += rerank(cosineF32x4));
    double whole(Object? Function(Float32List vector) stored, {int n = 20}) {
      final models = [
        for (var i = 0; i < _candidates; i++)
          _Doc.definition.hydrate({'id': i, 'embedding': stored(vectors[i])}),
      ];
      return _time(
        () => sink += rerankByCosine(models, query, 'embedding').length,
        warmUp: 3,
        rounds: n,
      );
    }

    final bytes = whole((v) => Uint8List.fromList(v.buffer.asUint8List()));
    final binary = whole((v) {
      final data = ByteData(4 + v.length * 4)..setUint16(0, v.length);
      for (var i = 0; i < v.length; i++) {
        data.setFloat32(4 + i * 4, v[i]);
      }
      return _undecoded(data.buffer.asUint8List(), binary: true);
    });
    final text = whole(
      (v) => _undecoded(
        utf8.encode('[${v.map(_shortest).join(',')}]'),
        binary: false,
      ),
      n: 5,
    );
    String us(double micros) => '${micros.toStringAsFixed(0)} µs';
    String perCosine(double micros) =>
        '${(micros * 1000 / _candidates).toStringAsFixed(0)} ns';
    print(
      '| $dimensions | ${us(scalar)} (${perCosine(scalar)}) '
      '| ${us(simd)} (${perCosine(simd)}) '
      '| ${(scalar / simd).toStringAsFixed(1)}× | ${us(bytes)} '
      '| ${us(binary)} | ${us(text)} |',
    );
  }
  if (sink.isNaN) {
    print(sink);
  }
}
