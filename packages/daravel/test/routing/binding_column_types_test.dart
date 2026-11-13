import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/database/column_values.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class Owner extends Model {
  static final ModelDefinition<Owner> definition = ModelDefinition<Owner>(
    table: 'bct_owners',
    factory: Owner.new,
    timestamps: false,
    relations: {
      'items': () =>
          HasMany<Item>(() => Item.definition, foreignKey: 'owner_id'),
    },
  );
  @override
  ModelDefinition<Owner> get modelDefinition => definition;
}

final class Item extends Model {
  static final ModelDefinition<Item> definition = ModelDefinition<Item>(
    table: 'bct_items',
    factory: Item.new,
    timestamps: false,
  );
  @override
  ModelDefinition<Item> get modelDefinition => definition;
}

/// A model keyed by a uuid column.
final class Ticket extends Model {
  static final ModelDefinition<Ticket> definition = ModelDefinition<Ticket>(
    table: 'bct_tickets',
    factory: Ticket.new,
    timestamps: false,
    keyType: KeyType.uuid,
  );
  @override
  ModelDefinition<Ticket> get modelDefinition => definition;
}

/// Runs the binding inside a transaction for `/tx/...`, then a query in the
/// same transaction: on PostgreSQL a refused statement would abort it.
final class _InTransaction implements Middleware {
  const _InTransaction();

  @override
  Future<Response> handle(Request request, Next next) {
    if (!request.path.startsWith('/tx/')) {
      return next(request);
    }
    return DB.transaction(() async {
      final response = await next(request);
      await DB.select('SELECT 1');
      return response;
    });
  }
}

/// The Laravel 13.40 golden: what implicit binding answers on PostgreSQL
/// and MySQL for an integer column given each value.
List<Map<String, Object?>> _golden(String dialect) {
  final json = jsonDecode(
    File('test/routing/fixtures/laravel_binding_non_text.json')
        .readAsStringSync(),
  ) as Map<String, Object?>;
  final runs = json['runs'] as Map<String, Object?>;
  final run = runs[dialect] as Map<String, Object?>;
  return [
    for (final row in run['binding field'] as List<Object?>)
      row as Map<String, Object?>,
  ];
}

void main() {
  group('ColumnValueType', () {
    ColumnValueType of(String type, [SqlDialect dialect = .postgres]) =>
        ColumnValueType.of(type, dialect);

    test('reads the column types of the three databases', () {
      for (final (type, kind) in [
        ('integer', ColumnValueKind.integer),
        ('bigint', ColumnValueKind.integer),
        ('smallint', ColumnValueKind.integer),
        ('int unsigned', ColumnValueKind.integer),
        ('bigint(20) unsigned', ColumnValueKind.integer),
        ('tinyint(1)', ColumnValueKind.integer),
        ('INTEGER', ColumnValueKind.integer),
        ('numeric(8,2)', ColumnValueKind.decimal),
        ('decimal(8,2)', ColumnValueKind.decimal),
        ('double precision', ColumnValueKind.decimal),
        ('real', ColumnValueKind.decimal),
        ('float', ColumnValueKind.decimal),
        ('character varying(255)', ColumnValueKind.text),
        ('varchar(255)', ColumnValueKind.text),
        ('character(36)', ColumnValueKind.text),
        ('char(36)', ColumnValueKind.text),
        ('text', ColumnValueKind.text),
        ('longtext', ColumnValueKind.text),
        ('uuid', ColumnValueKind.other),
        ('date', ColumnValueKind.other),
        ('timestamp(0) without time zone', ColumnValueKind.other),
        ('boolean', ColumnValueKind.other),
        ('jsonb', ColumnValueKind.other),
        ("enum('a','b')", ColumnValueKind.other),
        ('integer[]', ColumnValueKind.other),
        ('', ColumnValueKind.other),
      ]) {
        expect(of(type).kind, kind, reason: type);
      }
    });

    test('an integer: as PostgreSQL reads one, within the range', () {
      final integer = of('integer');
      for (final (value, parsed) in [
        ('7', 7),
        ('0', 0),
        ('007', 7),
        (' 7', 7),
        ('7 ', 7),
        ('\t7\n', 7),
        ('-0', 0),
        ('+7', 7),
        ('-7', -7),
        ('2147483647', 2147483647),
        ('-2147483648', -2147483648),
        ('${'0' * 40}7', 7),
      ]) {
        expect(integer.parse(value), parsed, reason: value);
      }
      for (final value in [
        'abc',
        '7abc',
        '7.0',
        '1e1',
        '9999999999999999999',
        '2147483648',
        '-2147483649',
        '',
        ' ',
        '-',
        '+',
        '--7',
        '0x1A',
        '1_000',
        '٧', // An Arabic-Indic seven.
      ]) {
        expect(integer.parse(value), isNull, reason: value);
      }
      expect(of('smallint').parse('32768'), isNull);
      expect(of('int unsigned', .mysql).parse('-1'), isNull);
      expect(of('int unsigned', .mysql).parse('4294967295'), 4294967295);
      expect(of('bigint').parse('-9223372036854775808'), -0x8000000000000000);
      expect(of('bigint').parse('9223372036854775808'), isNull);
      // SQLite keeps any integer in 64 bits, whatever the declared type.
      expect(of('integer', .sqlite).parse('2147483648'), 2147483648);
    });

    test('a decimal: a plain one, bound as text', () {
      final decimal = of('numeric(8,2)');
      for (final (value, parsed) in [
        ('7', '7'),
        ('-7.5', '-7.5'),
        ('.5', '.5'),
        ('7.', '7.'),
        (' 7.25 ', '7.25'),
      ]) {
        expect(decimal.parse(value), parsed, reason: value);
      }
      for (final value in [
        'abc',
        '1e1',
        '.',
        '7.0.0',
        '7,5',
        'NaN',
        'Infinity',
        '1' * 65,
      ]) {
        expect(decimal.parse(value), isNull, reason: value);
      }
    });

    test('text and other columns take the value as it is', () {
      expect(of('varchar(255)').parse(' a b '), ' a b ');
      expect(of('uuid').parse('abc'), 'abc');
    });

    test('reading a long value takes time in proportion to it', () {
      Duration time(String value) {
        final integer = of('bigint');
        final decimal = of('numeric');
        final watch = Stopwatch()..start();
        for (var i = 0; i < 5; i++) {
          integer.parse(value);
          decimal.parse(value);
        }
        return watch.elapsed;
      }

      final n = '0' * 200000;
      time(n); // Warm up.
      final small = time(n);
      final large = time('0' * 1600000);
      expect(
        large.inMicroseconds,
        lessThan(32 * (small.inMicroseconds + 1000)),
        reason: '8x the length took $large against $small',
      );
    });
  });

  test('a failed column read reaches every request waiting for it', () async {
    // Two requests, each in an error zone of its own, wait for the same
    // read of the column types, and it fails (nothing listens on port 1):
    // both answer 500. A future shared across the zones would leave the
    // second waiting for ever.
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_CONNECTION': 'pgsql',
          'DB_URL': 'postgres://nobody:nothing@127.0.0.1:1/none',
          'DB_CONNECT_TIMEOUT': '5',
        })
        .withLogLevel(LogLevel.critical)
        .withRouting(
          web: (router) {
            router.bindModel('item', Item.definition);
            router.get('/by-number/{item:number}', (r) => 'found');
          },
        )
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    final client = TestClient(app);
    final responses = await Future.wait([
      client.get('/by-number/7'),
      client.get('/by-number/8'),
    ]).timeout(const Duration(seconds: 20));
    expect([for (final r in responses) r.status], [500, 500]);
  });

  final pg = Platform.environment['DARAVEL_TEST_PG'];
  final runs = <String, Map<String, String> Function()>{
    'SQLite': () => {
      'DB_CONNECTION': 'sqlite',
      'DB_DATABASE': p.join(
        Directory.systemTemp.createTempSync('binding_types_').path,
        'db.sqlite',
      ),
    },
    if (pg != null && pg.isNotEmpty)
      'PostgreSQL': () => {'DB_CONNECTION': 'pgsql', 'DB_URL': pg},
  };
  const uuid7 = '0b9a2f8e-5c1d-4c47-9a3e-2f0d6c7b8a91';

  for (final MapEntry(key: name, value: env) in runs.entries) {
    group(name, () {
      late Application app;
      late TestClient client;

      Future<void> createTables() async {
        final schema = await Schema.builder();
        await schema.dropIfExists('bct_items');
        await schema.dropIfExists('bct_owners');
        await schema.dropIfExists('bct_tickets');
        await schema.create('bct_tickets', (table) {
          table.uuid('id').primary();
          table.string('title');
        });
        await DB.table('bct_tickets').insert([
          {'id': uuid7, 'title': 'seven'},
        ]);
        await schema.create('bct_owners', (table) => table.id());
        await schema.create('bct_items', (table) {
          table.id();
          table.integer('owner_id');
          table.integer('number');
          table.uuid('code');
          table.date('day');
          table.boolean('flag');
          table.string('label');
        });
        await DB.table('bct_owners').insert([
          {'id': 1},
          {'id': 2},
        ]);
        await DB.table('bct_items').insert([
          {
            'owner_id': 1,
            'number': 0,
            'code': '00000000-0000-4000-8000-000000000000',
            'day': '2026-01-01',
            'flag': false,
            'label': '0',
          },
          {
            'owner_id': 1,
            'number': 7,
            'code': uuid7,
            'day': '2026-01-07',
            'flag': true,
            'label': '007',
          },
        ]);
      }

      setUp(() async {
        app = Application.configure(basePath: Directory.systemTemp.path)
            .withEnv({'APP_ENV': 'testing', ...env()})
            .withLogLevel(LogLevel.critical)
            .withMiddleware((m) => m.use(const [_InTransaction()]))
            .withRouting(
              web: (router) {
                router
                  ..bindModel('item', Item.definition)
                  ..bindModel('owner', Owner.definition);
                Map<String, Object?> found(Request r) => {
                  'number': r.binding<Item>('item').getAttr<Object?>('number'),
                };
                for (final column in [
                  'number',
                  'code',
                  'day',
                  'flag',
                  'label',
                ]) {
                  router.get('/by-$column/{item:$column}', found);
                  router.get('/tx/by-$column/{item:$column}', found);
                }
                router.get('/by-id/{item}', found);
                router.get('/owners/{owner}/items/{item:number}', found);
                router.bindModel('ticket', Ticket.definition);
                Map<String, Object?> ticket(Request r) => {
                  'title': r
                      .binding<Ticket>('ticket')
                      .getAttr<Object?>('title'),
                };
                router.get('/tickets/{ticket}', ticket);
                router.get('/tx/tickets/{ticket}', ticket);
              },
            )
            .create();
        await app.boot();
        await app.run(createTables);
        client = TestClient(app);
      });

      tearDown(() async {
        await app.run(() async {
          final schema = await Schema.builder();
          await schema.dropIfExists('bct_items');
          await schema.dropIfExists('bct_owners');
          await schema.dropIfExists('bct_tickets');
        });
        await app.shutdown();
      });

      Future<TestResponse> get(String path, String value) =>
          client.get('$path/${Uri.encodeComponent(value)}');

      test('a uuid primary key given another shape: a 404, in a '
          'transaction too', () async {
        for (final prefix in ['', '/tx']) {
          for (final value in ['abc', '7', '$uuid7-x']) {
            final response = await get('$prefix/tickets', value);
            expect(response.status, 404, reason: '$prefix "$value"');
          }
          expect((await get('$prefix/tickets', uuid7)).json, {
            'title': 'seven',
          });
        }
      });

      test('the column types of the table are found', () async {
        // Not null: a type not found would silently compare the value as
        // it is (on MySQL, a word as 0).
        await app.run(() async {
          final manager = Container.current.make<DatabaseManager>();
          final type = await ColumnValueTypes.of(
            manager,
            null,
            'bct_items',
            'number',
          );
          expect(type?.kind, ColumnValueKind.integer);
          if (name == 'PostgreSQL') {
            // A schema-qualified name reads that schema's table.
            final qualified = await ColumnValueTypes.of(
              manager,
              null,
              'public.bct_items',
              'number',
            );
            expect(qualified?.kind, ColumnValueKind.integer);
          }
        });
      });

      test('an integer column: as Laravel on PostgreSQL, a 404 for its 500 '
          '(the Laravel 13.40 golden)', () async {
        for (final row in _golden('pgsql')) {
          final value = row['value']! as String;
          for (final path in ['/by-number', '/tx/by-number']) {
            final response = await get(path, value);
            if (row['status'] == 200) {
              expect(response.status, 200, reason: '$path "$value"');
              expect(response.json, {'number': row['number']}, reason: value);
            } else {
              expect(response.status, 404, reason: '$path "$value"');
            }
          }
        }
      });

      test('uuid, date and boolean columns: a value of another shape is a '
          '404, in a transaction too', () async {
        for (final prefix in ['', '/tx']) {
          for (final (column, value) in [
            ('code', 'abc'),
            ('code', '7'),
            ('day', 'abc'),
            ('day', '2026-13-45'),
            ('flag', 'abc'),
          ]) {
            final response = await get('$prefix/by-$column', value);
            expect(response.status, 404, reason: '$prefix $column "$value"');
          }
          expect((await get('$prefix/by-code', uuid7)).json, {'number': 7});
          expect((await get('$prefix/by-day', '2026-01-07')).json, {
            'number': 7,
          });
        }
      });

      test('a text column compares the value as it is', () async {
        expect((await get('/by-label', '007')).json, {'number': 7});
        expect((await get('/by-label', '7')).status, 404);
      });

      test('scoped to its parent, by an integer column', () async {
        expect((await get('/owners/1/items', '7')).json, {'number': 7});
        expect((await get('/owners/1/items', '007')).json, {'number': 7});
        expect((await get('/owners/2/items', '7')).status, 404);
        expect((await get('/owners/1/items', 'abc')).status, 404);
      });

      test('the primary key path is unchanged: no schema query', () async {
        final sql = <String>[];
        await app.run(() async {
          final stop = DB.listen((event) => sql.add(event.sql));
          try {
            expect((await get('/by-id', '2')).json, {'number': 7});
            expect((await get('/by-id', 'abc')).status, 404);
          } finally {
            stop();
          }
        });
        // One lookup by the key, no schema query; nothing for a word.
        expect(sql, hasLength(1));
        expect(sql.single.toLowerCase(), startsWith('select * from '));
        expect(sql.single.toLowerCase(), contains('."id" = '));
      });

      test('the column types are read once, and again after the schema '
          'changed', () async {
        final reads = <String>[];
        bool schemaRead(String sql) =>
            sql.contains('table_info') ||
            sql.contains('information_schema') ||
            sql.contains('pg_attribute');
        await app.run(() async {
          final stop = DB.listen((event) {
            if (schemaRead(event.sql)) {
              reads.add(event.sql);
            }
          });
          try {
            expect((await get('/by-number', '007')).json, {'number': 7});
            expect((await get('/by-number', '7')).json, {'number': 7});
            expect(reads, hasLength(1), reason: 'once for the table');
            // `number` becomes text: '007' then means the text '007'.
            await Schema.table(
              'bct_items',
              (table) => table.string('number').change(),
            );
            await DB.table('bct_items').where('number', '7').update({
              'number': '007',
            });
            reads.clear();
            expect((await get('/by-number', '007')).json, {'number': '007'});
            expect((await get('/by-number', '7')).status, 404);
            expect(reads, hasLength(1), reason: 'read again after the change');
          } finally {
            stop();
          }
        });
      });
    });
  }
}
