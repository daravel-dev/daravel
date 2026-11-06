import 'dart:async';
import 'dart:convert';

import 'package:daravel/daravel.dart';

import 'config.dart';

/// Makes the applications a Pusher server serves, at boot: what
/// `withReverb(apps:)` takes.
typedef ReverbAppsFactory = BroadcastAppProvider Function(Container c);

/// The application providers of `withReverb()` (Blueprint #135 §3.2).
abstract final class ReverbApps {
  /// By `REVERB_APPS_PROVIDER`: [fromEnv] (`config`) or [database].
  static BroadcastAppProvider fromSource(Container c) =>
      switch (c.make<ConfigRepository>().section<ReverbConfig>().source) {
        ReverbAppsSource.config => fromEnv(c),
        ReverbAppsSource.database => database()(c),
      };

  /// The applications of `REVERB_APPS`, with the one of the `REVERB_APP_*`
  /// settings unless the list has its id or key; only that one when
  /// `REVERB_APPS` is empty (a server as `withBroadcasting()` alone).
  static BroadcastAppProvider fromEnv(Container c) {
    final config = c.make<ConfigRepository>();
    final settings = config.section<BroadcastConfig>();
    final listed = config.section<ReverbConfig>().apps;
    if (listed.isEmpty) {
      return SingleAppProvider.fromConfig(settings);
    }
    final own = settings.serves ? BroadcastApp.fromConfig(settings) : null;
    return ListAppProvider([
      if (own != null &&
          !listed.any((app) => app.id == own.id || app.key == own.key))
        own,
      ...listed,
    ]);
  }

  /// The applications of the `reverb_apps` table
  /// ([CreateReverbAppsTable]) on [connection], each kept
  /// `REVERB_APPS_CACHE_TTL` (60 s) in the isolate that read it; the one of
  /// the `REVERB_APP_*` settings first.
  static ReverbAppsFactory database({String? connection}) => (c) {
    final config = c.make<ConfigRepository>();
    final settings = config.section<BroadcastConfig>();
    return DatabaseAppProvider(
      c.make<DatabaseManager>(),
      connection: connection,
      ttl: config.section<ReverbConfig>().appsCacheTtl,
      settings: settings.serves ? BroadcastApp.fromConfig(settings) : null,
    );
  };
}

/// The applications of the `reverb_apps` table: one row per tenant,
/// columns as the entries of `REVERB_APPS` (`allowed_origins` and
/// `rate_limiting` as JSON text).
///
/// What it reads, and what it does not find, is kept [ttl] in this isolate,
/// so a connection costs no query; a changed row is seen after [ttl], or at
/// once after [forget]. Frames are bounded by `REVERB_APP_MAX_MESSAGE_SIZE`
/// (the table is not read at boot), each app's `max_message_size` below it.
final class DatabaseAppProvider implements BroadcastAppProvider {
  /// The provider reading [table] on [connection] of [database].
  DatabaseAppProvider(
    this.database, {
    this.connection,
    this.table = 'reverb_apps',
    this.ttl = const Duration(seconds: 60),
    this.settings,
  });

  /// The database.
  final DatabaseManager database;

  /// The connection; the default one when null.
  final String? connection;

  /// The table.
  final String table;

  /// How long a lookup is kept.
  final Duration ttl;

  /// The application of the `REVERB_APP_*` settings, served without a row.
  final BroadcastApp? settings;

  final Map<String, ({BroadcastApp? app, DateTime until})> _cache = {};

  @override
  FutureOr<BroadcastApp?> byKey(String key) =>
      settings?.key == key ? settings : _lookup('key', key);

  @override
  FutureOr<BroadcastApp?> byId(String id) =>
      settings?.id == id ? settings : _lookup('app_id', id);

  /// Drops what was kept, so the next lookup reads the table.
  void forget() => _cache.clear();

  FutureOr<BroadcastApp?> _lookup(String column, String value) {
    final cacheKey = '$column:$value';
    final kept = _cache[cacheKey];
    final now = Clock.now();
    if (kept != null && now.isBefore(kept.until)) {
      return kept.app;
    }
    return _read(column, value).then((app) {
      _cache[cacheKey] = (app: app, until: now.add(ttl));
      return app;
    });
  }

  Future<BroadcastApp?> _read(String column, String value) async {
    final row = await database
        .table(table, connection: connection)
        .where(column, value)
        .first();
    if (row == null) {
      return null;
    }
    final entry = {
      for (final MapEntry(:key, :value) in row.entries)
        key:
            (key == 'allowed_origins' || key == 'rate_limiting') &&
                value is String &&
                value.isNotEmpty
            ? jsonDecode(value)
            : value,
    };
    return ReverbConfig.appFromMap(entry, '$table row ${row['app_id']}');
  }
}

/// Creates `reverb_apps`, the table of [DatabaseAppProvider]:
/// `withMigrations([...migrations, const CreateReverbAppsTable()])`.
final class CreateReverbAppsTable extends Migration {
  /// The migration.
  const CreateReverbAppsTable();

  @override
  String get name => '2026_11_07_000000_create_reverb_apps_table';

  @override
  Future<void> up(SchemaBuilder schema) async {
    if (await schema.hasTable('reverb_apps')) {
      return;
    }
    await schema.create('reverb_apps', (table) {
      table.id();
      table.string('app_id').unique();
      table.string('key').unique();
      table.string('secret');
      table.text('allowed_origins').nullable();
      table.integer('max_connections').nullable();
      table.integer('max_message_size').nullable();
      table.integer('activity_timeout').nullable();
      table.text('rate_limiting').nullable();
      table.string('encryption_master_key').nullable();
      table.timestamps();
    });
  }

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('reverb_apps');
}
