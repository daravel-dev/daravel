@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'secretbox_vectors.dart';

/// secretbox_vectors.dart holds the fixtures as Dart data (so they run in a
/// browser): it must say what the fixture files say.
void main() {
  final fixtures = '${Directory.current.path}/test/fixtures';

  test('the NaCl vector is the fixture', () {
    final vector = jsonDecode(
      File('$fixtures/secretbox_nacl.json').readAsStringSync(),
    ) as Map<String, Object?>;
    expect(
      (
        key: vector['key'],
        nonce: vector['nonce'],
        message: vector['message'],
        box: vector['box'],
      ),
      (
        key: naclVector.key,
        nonce: naclVector.nonce,
        message: naclVector.message,
        box: naclVector.box,
      ),
    );
  });

  test('the PHP sodium vectors are the fixture, row by row', () {
    final rows = File('$fixtures/secretbox_php_sodium.jsonl')
        .readAsLinesSync()
        .where((line) => line.startsWith('{'))
        .map((line) => jsonDecode(line) as Map<String, Object?>)
        .toList();
    expect(
      [
        for (final r in rows)
          (
            len: r['len'],
            key: r['key'],
            nonce: r['nonce'],
            message: r['message'],
            box: r['box'],
          ),
      ],
      [
        for (final v in phpVectors)
          (
            len: v.len,
            key: v.key,
            nonce: v.nonce,
            message: v.message,
            box: v.box,
          ),
      ],
    );
  });
}
