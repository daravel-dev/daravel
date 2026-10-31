import 'dart:convert';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Laravel's `$incrementing = false` on an integer key.
final class Seat extends Model {
  static final ModelDefinition<Seat> definition = ModelDefinition<Seat>(
    table: 'seats',
    factory: Seat.new,
    keyType: .manualInt,
    fillable: ['id', 'label'],
    timestamps: false,
  );

  @override
  ModelDefinition<Seat> get modelDefinition => Seat.definition;
}

void main() {
  late DatabaseManager db;
  ModelQuery<Seat> seats() => Seat.definition.query(db: db);

  setUp(() async {
    db = DatabaseManager(
      DatabaseConfig(
        defaultConnection: 'sqlite',
        connections: {
          'sqlite': ConnectionConfig(driver: 'sqlite', database: ':memory:'),
        },
      ),
    );
    await db.statement(
      'CREATE TABLE seats (id INTEGER PRIMARY KEY, label TEXT NOT NULL)',
    );
  });

  tearDown(() => db.closeAll());

  group('KeyType.manualInt', () {
    test('keeps the key the application gives', () async {
      final seat = await seats().create({'id': 42, 'label': 'A'});
      expect(seat.getAttr<int>('id'), 42);
      expect((await seats().find(42))!.getAttr<String>('label'), 'A');
    });

    test('a new model without a key is an error, not a generated id', () {
      expect(seats().create({'label': 'A'}), throwsStateError);
    });
  });

  test('ModelQuery.orderByRaw binds its values', () async {
    await seats().create({'id': 1, 'label': 'A'});
    await seats().create({'id': 2, 'label': 'B'});
    await seats().create({'id': 3, 'label': 'C'});
    final rows = await seats().orderByRaw(
      'CASE WHEN label = ? THEN 0 ELSE 1 END, id DESC',
      ['B'],
    ).get();
    expect([for (final seat in rows) seat.getAttr<int>('id')], [2, 3, 1]);
  });

  test('inputSync sees the body once it was awaited', () async {
    final request = Request.fake(
      method: 'POST',
      path: '/x',
      query: const {'page': '5', 'name': 'query'},
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({'name': 'body'}),
    );
    expect(request.inputSync<int>('page'), 5);
    expect(request.inputSync<String>('name'), 'query');
    await request.all();
    expect(request.inputSync<String>('name'), 'body');
    expect(request.inputSync<int>('missing', 3), 3);
  });

  test('inputSync fails loudly when an unread body would be skipped', () async {
    final body = jsonEncode({'name': 'body'});
    final request = Request.fake(
      method: 'POST',
      path: '/x',
      query: const {'page': '5'},
      headers: {
        'content-type': 'application/json',
        'content-length': '${body.length}',
      },
      body: body,
    );
    expect(request.inputSync<int>('page'), 5, reason: 'the query answers');
    expect(
      () => request.inputSync<String>('name'),
      throwsA(isA<AssertionError>()),
    );
    await request.all();
    expect(request.inputSync<String>('name'), 'body');
  });
}
