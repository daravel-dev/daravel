import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import 'support/test_databases.dart';

final class Show extends Model {
  static final ModelDefinition<Show> definition = ModelDefinition<Show>(
    table: 'shows',
    factory: Show.new,
    guarded: [],
    timestamps: false,
    relations: {
      'tickets': () => HasMany<ShowTicket>(
        () => ShowTicket.definition,
        foreignKey: 'show_id',
      ),
    },
  );
  @override
  ModelDefinition<Show> get modelDefinition => Show.definition;
}

final class ShowTicket extends Model {
  static final ModelDefinition<ShowTicket> definition =
      ModelDefinition<ShowTicket>(
        table: 'show_tickets',
        factory: ShowTicket.new,
        guarded: [],
        timestamps: false,
      );
  @override
  ModelDefinition<ShowTicket> get modelDefinition => ShowTicket.definition;
}

void main() => forEachDatabase(dateQueryAndGuardTests);

/// Laravel 11 date shortcuts and query guards against a real database. Also
/// run on MySQL and MariaDB by daravel_mysql/test/orm_matrix_test.dart.
void dateQueryAndGuardTests(DatabaseOpener open) {
  late DatabaseManager db;

  setUp(() async {
    db = open();
    final schema = await freshSchema(db, ['shows', 'show_tickets']);
    await schema.create('shows', (t) {
      t.id();
      t.string('name');
      t.timestamp('starts_at');
    });
    await schema.create('show_tickets', (t) {
      t.id();
      t.integer('show_id');
    });
    Clock.travelTo(DateTime.utc(2026, 10, 25, 12));
    for (final (name, startsAt) in [
      ('yesterday', '2026-10-24 18:00:00'),
      ('this morning', '2026-10-25 08:00:00'),
      ('tonight', '2026-10-25 20:00:00'),
      ('tomorrow', '2026-10-26 09:00:00'),
    ]) {
      final id = await db.table('shows').insertGetId({
        'name': name,
        'starts_at': startsAt,
      });
      await db.table('show_tickets').insert([
        {'show_id': id},
        {'show_id': id},
      ]);
    }
  });
  tearDown(() async {
    Clock.restore();
    await db.closeAll();
  });

  Future<List<Object?>> names(ModelQuery<Show> query) async =>
      await query.orderBy('id').pluck('name') as List<Object?>;
  ModelQuery<Show> shows() => Show.definition.query(db: db);

  test('Laravel 11 date shortcuts against the Clock', () async {
    expect(await names(shows().wherePast('starts_at')), [
      'yesterday',
      'this morning',
    ]);
    expect(await names(shows().whereNowOrPast('starts_at')), [
      'yesterday',
      'this morning',
    ]);
    expect(await names(shows().whereFuture('starts_at')), [
      'tonight',
      'tomorrow',
    ]);
    expect(await names(shows().whereToday('starts_at')), [
      'this morning',
      'tonight',
    ]);
    expect(await names(shows().whereBeforeToday('starts_at')), ['yesterday']);
    expect(await names(shows().whereTodayOrBefore('starts_at')), [
      'yesterday',
      'this morning',
      'tonight',
    ]);
    expect(await names(shows().whereAfterToday('starts_at')), ['tomorrow']);
    expect(await names(shows().whereTodayOrAfter('starts_at')), [
      'this morning',
      'tonight',
      'tomorrow',
    ]);
    expect(
      await names(
        shows().whereBeforeToday('starts_at').orWhereAfterToday('starts_at'),
      ),
      ['yesterday', 'tomorrow'],
    );
    expect(
      await names(shows().where('name', 'tonight').orWherePast('starts_at')),
      ['yesterday', 'this morning', 'tonight'],
    );
    expect(await names(shows().whereYear('starts_at', 2026)), hasLength(4));
    expect(await names(shows().whereMonth('starts_at', 10)), hasLength(4));
    expect(await names(shows().whereDay('starts_at', 26)), ['tomorrow']);
    // The query builder has them too.
    expect(await db.table('shows').whereToday('starts_at').count(), 2);
  });

  test('withQueryCount proves eager loading removes the N+1', () async {
    final (lazy, lazyQueries) = await db.captureQueries(() async {
      final list = await shows().get();
      for (final show in list) {
        await show.relatedQuery<ShowTicket>('tickets').get();
      }
      return list;
    });
    expect(lazy, hasLength(4));
    expect(lazyQueries, hasLength(5), reason: '1 + one query per show');

    final (_, queries) = await db.captureQueries(
      () => shows().with_('tickets').get(),
    );
    expect(queries, hasLength(2));
    expect(queries.last.sql, contains('show_tickets'));
  });

  test('whenQueryingForLongerThan fires once per scope on the total', () async {
    final fired = <String>[];
    db.whenQueryingForLongerThan(
      Duration.zero,
      (event) => fired.add(event.sql),
    );
    final container = Container();
    await container.runScoped<void>('request', (_) async {
      await shows().get();
      await shows().get();
    });
    await container.runScoped<void>('request', (_) async {
      await shows().get();
    });
    expect(fired, hasLength(2), reason: 'one per request scope');
    await container.runScoped<void>('job', (_) async {
      await shows().get();
      expect(db.totalQueryDuration, greaterThan(Duration.zero));
    });
  });
}
