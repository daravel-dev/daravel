import 'dart:convert';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `Response.streamJson` / `jsonArrayBytes` / `QueryBuilder.streamJson`:
/// a JSON array written in chunks, byte for byte what `Response.json`
/// writes for the collected list.
void main() {
  final items = [
    for (var i = 1; i <= 5; i++)
      {
        'id': i,
        'path': '/users/$i',
        'name': 'User ${String.fromCharCode(0xE9)}$i',
        'meta': <String, Object?>{},
        'at': DateTime.utc(2026, 10, i),
      },
  ];

  Future<String> text(Stream<List<int>> bytes) async =>
      utf8.decode([for (final chunk in await bytes.toList()) ...chunk]);

  group('jsonArrayBytes', () {
    test('an empty stream is [] (or the wrapped object)', () async {
      expect(await text(jsonArrayBytes(const Stream<Object?>.empty())), '[]');
      expect(
        await text(jsonArrayBytes(const Stream<Object?>.empty(), wrap: 'data')),
        '{"data":[]}',
      );
    });

    test('writes what Response.json writes, in several chunks', () async {
      final chunks = await jsonArrayBytes(
        Stream.fromIterable(items),
        flushBytes: 100,
      ).toList();
      expect(chunks.length, greaterThan(2));
      final joined = utf8.decode([for (final c in chunks) ...c]);
      expect(joined, Response.encodeJson(items));
      expect(jsonDecode(joined), jsonDecode(Response.encodeJson(items)));
    });

    test('phpCompatible writes the json_encode bytes', () async {
      expect(
        await text(
          jsonArrayBytes(Stream.fromIterable(items), phpCompatible: true),
        ),
        Response.encodePhpJson(items),
      );
      expect(
        await text(
          jsonArrayBytes(
            Stream.fromIterable(items),
            phpCompatible: true,
            wrap: 'a/b',
          ),
        ),
        '{"a\\/b":${Response.encodePhpJson(items)}}',
      );
    });
  });

  test('Response.streamJson is an application/json streamed body', () async {
    final response = Response.streamJson(
      Stream.fromIterable(items),
      wrap: 'data',
    );
    expect(response.status, 200);
    expect(response.headers.contentType, 'application/json');
    expect(response.body, isA<StreamBody>());
    expect(await response.bodyText(), Response.encodeJson({'data': items}));
  });

  group('QueryBuilder.streamJson', () {
    late DatabaseManager db;

    setUp(() async {
      db = DatabaseManager(
        const DatabaseConfig(
          defaultConnection: 'sqlite',
          connections: {
            'sqlite': ConnectionConfig(driver: 'sqlite', database: ':memory:'),
          },
        ),
      );
      await db.statement(
        'CREATE TABLE users ("id" INTEGER PRIMARY KEY AUTOINCREMENT, '
        '"name" TEXT, "path" TEXT)',
      );
      await db.table('users').insert([
        for (var i = 1; i <= 5; i++)
          {'name': 'User ${String.fromCharCode(0xE9)}$i', 'path': '/u/$i'},
      ]);
    });

    test('streams the rows of several page queries as one array', () async {
      final query = db.table('users').orderBy('id');
      final rows = await query.get();
      expect(rows, hasLength(5));
      expect(await text(query.streamJson(chunk: 2)), Response.encodeJson(rows));
      expect(
        await text(query.streamJson(chunk: 2, phpCompatible: true)),
        Response.encodePhpJson(rows),
      );
      expect(
        await text(db.table('users').where('id', '>', 99).streamJson()),
        '[]',
      );
    });

    test('feeds Response.streamJson through lazy()', () async {
      final response = Response.streamJson(
        db.table('users').orderBy('id').lazy(2),
      );
      expect(
        jsonDecode(await response.bodyText()),
        jsonDecode(Response.encodeJson(await db.table('users').get())),
      );
    });
  });
}
