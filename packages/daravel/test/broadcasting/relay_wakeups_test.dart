import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import '../database/support/test_databases.dart';

/// The database relay of several servers, when the stream that wakes it
/// (PostgreSQL's `LISTEN`) fails: the error is reported, and the relay goes
/// on reading. Here SQLite with a `LISTEN` the test controls.
void main() {
  late Directory dir;
  late Application app;
  final listens = <StreamController<String>>[];

  setUp(() async {
    listens.clear();
    dir = Directory.systemTemp.createTempSync('daravel_relay_wakeups_');
    app = Application.configure(basePath: dir.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': '${dir.path}/relay.sqlite',
        })
        .withDatabaseDriver(
          'sqlite',
          (name, connection) =>
              _Listening(SqliteDriver.fromConfig(name, connection), listens),
        )
        .create();
    await app.boot();
    await app.run(() async {
      final schema = await freshSchema(App.make<DatabaseManager>(), const [
        'broadcast_messages',
        'broadcast_members',
        'broadcast_servers',
        'broadcast_cache',
      ]);
      await const CreateBroadcastingTables().up(schema);
    });
  });

  tearDown(() async {
    await app.shutdown();
    dir.deleteSync(recursive: true);
  });

  test('a LISTEN stream that fails is reported, and the relay goes on '
      'delivering', () async {
    await app.run(() async {
      final db = App.make<DatabaseManager>();
      final errors = <Object>[];
      final delivered = <String>[];
      DatabaseBroadcastRelay relay(String server) => DatabaseBroadcastRelay(
        db,
        state: DatabaseChannelState(db, server: server),
        poll: const Duration(milliseconds: 20),
        onError: errors.add,
      );
      final reader = relay('a');
      final sender = relay('b');
      await reader.start((channel, envelope) => delivered.add(envelope));
      expect(listens, isNotEmpty, reason: 'the relay listens');
      listens.last.addError(const SocketException('LISTEN connection lost'));
      await sender.send('news', 'x\n{"event":"e"}');
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (delivered.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(errors, [isA<SocketException>()]);
      expect(delivered, ['x\n{"event":"e"}']);
      await reader.close();
      await sender.close();
    });
  });
}

/// SQLite with a `LISTEN` whose streams the test feeds.
final class _Listening implements NotifyingDriver {
  _Listening(this._inner, this._listens);

  final DatabaseDriver _inner;
  final List<StreamController<String>> _listens;

  @override
  Stream<String> listen(String channel) {
    final controller = StreamController<String>();
    _listens.add(controller);
    return controller.stream;
  }

  @override
  String get name => _inner.name;
  @override
  SqlDialect get dialect => _inner.dialect;
  @override
  bool get isConnected => _inner.isConnected;
  @override
  Future<void> connect() => _inner.connect();
  @override
  Future<void> close() => _inner.close();
  @override
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) => _inner.select(sql, bindings);
  @override
  Future<int> execute(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) => _inner.execute(sql, bindings);
  @override
  Future<Object?> insertGetId(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) => _inner.insertGetId(sql, bindings);
  @override
  Future<T> transaction<T>(Future<T> Function(QueryExecutor tx) body) =>
      _inner.transaction(body);
}
