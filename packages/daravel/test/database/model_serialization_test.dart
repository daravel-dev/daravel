import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `Model.toJson` against Laravel's `HasAttributes::attributesToArray`
/// (laravel/framework 8.83.27, 9.x and 12.70.1 behave the same): an
/// `$appends` entry that names an existing attribute replaces it in place,
/// and a `datetime:FORMAT` cast formats timestamps in UTC, because
/// `addDateAttributesToArray` serializes them with `Carbon::toJSON()` (UTC)
/// before `addCastAttributesToArray` re-parses and formats them.
final class Article extends Model {
  static final ModelDefinition<Article> definition = ModelDefinition<Article>(
    table: 'articles',
    factory: Article.new,
    guarded: [],
    casts: {
      'created_at': Cast.dateTimeFormat('Y-m-d H:i:s'),
      'updated_at': Cast.dateTimeFormat(r'D, d M Y \a\t H:i'),
      'published_at': Cast.dateTimeFormat('d/m/Y'),
      'reviewed_at': Cast.dateTime,
    },
    appends: ['title', 'slug'],
    accessors: {
      'title': (a) => '${a.attributes['title']}'.toUpperCase(),
      'slug': (a) =>
          '${a.attributes['title']}'.toLowerCase().replaceAll(' ', '-'),
    },
  );

  @override
  ModelDefinition<Article> get modelDefinition => Article.definition;
}

/// Laravel skips the cast of an attribute that has an accessor
/// (`addCastAttributesToArray` leaves `$mutatedAttributes` alone).
final class AccessedArticle extends Model {
  static final ModelDefinition<AccessedArticle> definition =
      ModelDefinition<AccessedArticle>(
        table: 'articles',
        factory: AccessedArticle.new,
        casts: {'created_at': Cast.dateTimeFormat('Y')},
        accessors: {
          'created_at': (a) => 'accessed ${a.attributes['created_at']}',
        },
      );

  @override
  ModelDefinition<AccessedArticle> get modelDefinition =>
      AccessedArticle.definition;
}

Future<void> _createTable(DatabaseManager db) async {
  final schema = SchemaBuilder(await db.executor());
  await schema.create('articles', (t) {
    t.id();
    t.string('title');
    t.integer('views').defaultTo(0);
    t.timestamp('published_at').nullable();
    t.timestamp('reviewed_at').nullable();
    t.timestamps();
  });
}

Future<Map<String, Object?>> _articleJson(DatabaseManager db) async {
  await _createTable(db);
  Clock.travelTo(DateTime.utc(2021, 1, 1, 10, 0, 0));
  final created = await Article.definition.query(db: db).create({
    'title': 'Hello World',
    'views': 3,
    'published_at': '2021-01-02 23:30:00',
    'reviewed_at': '2021-01-03 08:15:00',
  });
  final article = await Article.definition
      .query(db: db)
      .findOrFail(created.key!);
  return article.toJson();
}

const _expectedJson = <String, Object?>{
  'id': 1,
  'title': 'HELLO WORLD',
  'views': 3,
  'published_at': '02/01/2021',
  'reviewed_at': '2021-01-03T08:15:00.000000Z',
  'created_at': '2021-01-01 10:00:00',
  'updated_at': 'Fri, 01 Jan 2021 at 10:00',
  'slug': 'hello-world',
};

void main() {
  tearDown(Clock.restore);

  group('formatPhpDate', () {
    final t = DateTime.utc(2024, 2, 29, 13, 5, 9, 7, 8);

    test('writes every PHP date() token for a UTC value', () {
      const tokens = {
        'd': '29',
        'D': 'Thu',
        'j': '29',
        'l': 'Thursday',
        'N': '4',
        'S': 'th',
        'w': '4',
        'z': '59',
        'W': '09',
        'F': 'February',
        'm': '02',
        'M': 'Feb',
        'n': '2',
        't': '29',
        'L': '1',
        'o': '2024',
        'Y': '2024',
        'y': '24',
        'a': 'pm',
        'A': 'PM',
        'B': '586',
        'g': '1',
        'G': '13',
        'h': '01',
        'H': '13',
        'i': '05',
        's': '09',
        'u': '007008',
        'v': '007',
        'e': 'UTC',
        'I': '0',
        'O': '+0000',
        'P': '+00:00',
        'p': 'Z',
        'T': 'UTC',
        'Z': '0',
        'c': '2024-02-29T13:05:09+00:00',
        'r': 'Thu, 29 Feb 2024 13:05:09 +0000',
        'U': '1709211909',
      };
      for (final entry in tokens.entries) {
        expect(formatPhpDate(t, entry.key), entry.value, reason: entry.key);
      }
    });

    test('escapes with a backslash and copies other characters', () {
      expect(formatPhpDate(t, 'Y-m-d H:i:s'), '2024-02-29 13:05:09');
      expect(formatPhpDate(t, r'Y-m-d\TH:i:s'), '2024-02-29T13:05:09');
      expect(formatPhpDate(t, r'\Y\e\a\r Y'), 'Year 2024');
      expect(formatPhpDate(t, 'jS F, g:i a'), '29th February, 1:05 pm');
      expect(formatPhpDate(DateTime.utc(2024, 2, 1), 'jS'), '1st');
      expect(formatPhpDate(DateTime.utc(2024, 2, 2), 'jS'), '2nd');
      expect(formatPhpDate(DateTime.utc(2024, 2, 3), 'jS'), '3rd');
      expect(formatPhpDate(DateTime.utc(2024, 2, 11), 'jS'), '11th');
      expect(formatPhpDate(DateTime.utc(2024, 2, 22), 'jS'), '22nd');
    });

    test('ISO week and year cross the calendar year as PHP does', () {
      expect(formatPhpDate(DateTime.utc(2021, 1, 1), 'o-W N'), '2020-53 5');
      expect(formatPhpDate(DateTime.utc(2024, 12, 30), 'o-W N'), '2025-01 1');
      expect(formatPhpDate(DateTime.utc(2023, 1, 1), 'w z L t'), '0 0 0 31');
      expect(formatPhpDate(DateTime.utc(2023, 12, 31), 'z'), '364');
    });

    test('converts a local value to UTC first', () {
      final local = DateTime.utc(2024, 2, 29, 23, 30).toLocal();
      expect(formatPhpDate(local, 'Y-m-d H:i T'), '2024-02-29 23:30 UTC');
      expect(formatPhpDate(DateTime.utc(1969, 12, 31, 23, 59, 59), 'U'), '-1');
    });
  });

  group('Model.toJson', () {
    late DatabaseManager db;

    setUp(() {
      db = DatabaseManager(
        const DatabaseConfig(
          defaultConnection: 'sqlite',
          connections: {
            'sqlite': ConnectionConfig(driver: 'sqlite', database: ':memory:'),
          },
        ),
      );
    });

    tearDown(() => db.closeAll());

    test('an append naming an attribute replaces it in place; '
        'datetime:FORMAT casts format in UTC; others stay ISO-8601', () async {
      final json = await _articleJson(db);
      expect(json, _expectedJson);
      expect(json.keys.toList(), _expectedJson.keys.toList());
    });

    test('a datetime:FORMAT attribute reads as a DateTime', () async {
      await _createTable(db);
      final article = Article()
        ..attachDatabase(db)
        ..setAttr('created_at', DateTime.utc(2021, 1, 1, 10));
      expect(article.attributes['created_at'], '2021-01-01 10:00:00');
      expect(
        article.getAttr<DateTime?>('created_at'),
        DateTime.utc(2021, 1, 1, 10),
      );
      expect(article.toJson()['created_at'], '2021-01-01 10:00:00');
      article.setAttr('created_at', null);
      expect(article.toJson()['created_at'], isNull);
    });

    test('an accessor on a formatted attribute wins over the cast', () {
      final article = AccessedArticle()
        ..hydrateFrom({'id': 1, 'created_at': '2021-01-01 10:00:00'});
      expect(article.toJson(), {
        'id': 1,
        'created_at': 'accessed 2021-01-01 10:00:00',
      });
    });
  });

  group('COMPAT_LARAVEL_VERSION', () {
    Future<Application> boot(String? version) async {
      final base = Directory.systemTemp.createTempSync('daravel_model_compat');
      final app = Application.configure(basePath: base.path).withEnv({
        'APP_ENV': 'testing',
        'DB_DATABASE': ':memory:',
        'COMPAT_LARAVEL_VERSION': ?version,
      }).create();
      await app.boot();
      addTearDown(() async {
        await app.shutdown();
        base.deleteSync(recursive: true);
      });
      return app;
    }

    // Laravel 8 (8.83.27), 9.x and 12 (12.70.1) serialize appends and
    // `datetime:FORMAT` casts the same way, so the preset changes nothing
    // here: the same JSON under 8 and under the default.
    for (final version in ['8', '9', null]) {
      test(
        'Laravel ${version ?? '12 (default)'} writes the same JSON',
        () async {
          final app = await boot(version);
          expect(
            currentLaravelCompat(),
            version == null
                ? AppConfig.defaultLaravelCompat
                : int.parse(version),
          );
          final json = await _articleJson(
            app.container.make<DatabaseManager>(),
          );
          expect(json, _expectedJson);
          expect(json.keys.toList(), _expectedJson.keys.toList());
        },
      );
    }
  });
}
