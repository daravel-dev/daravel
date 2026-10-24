import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:test/test.dart';

void main() {
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
      'CREATE TABLE "posts" ("id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
      '"title" VARCHAR(120) NOT NULL, "body" TEXT, "views" INTEGER DEFAULT 0)',
    );
    await db.statement('CREATE TABLE "tags" ("name" TEXT)');
    await db.table('posts').insert({'title': 'Hello'});
  });
  tearDown(() => db.closeAll());

  test('db:show lists tables with column and row counts', () async {
    expect(await describeDatabase(db), [
      ['Table', 'Columns', 'Rows'],
      ['posts', '4', '1'],
      ['tags', '1', '0'],
    ]);
  });

  test('db:table describes columns; unknown tables are null', () async {
    final rows = (await describeTable(db, 'posts'))!;
    expect(rows.first, ['Column', 'Type', 'Nullable', 'Default', 'Key']);
    expect(rows[1], ['id', 'INTEGER', 'no', '', 'primary, auto increment']);
    expect(rows[2], ['title', 'VARCHAR(120)', 'no', '', '']);
    expect(rows[4][3], '0');
    expect(await describeTable(db, 'missing'), isNull);
  });

  test('tinker wraps the expression in a booted application scope', () {
    final script = renderTinkerScript([
      'package:blog/app/models/user.dart',
    ], 'await User.query().count()');
    expect(script, contains("import 'package:blog/app/models/user.dart';"));
    expect(script, contains("import '../../bootstrap/app.dart';"));
    expect(script, contains('() async => await User.query().count(),'));
    expect(script, contains('await app.boot();'));
    expect(script, contains('await app.shutdown();'));
  });
}
