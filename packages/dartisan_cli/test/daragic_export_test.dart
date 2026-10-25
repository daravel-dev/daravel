import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class Author extends Model {
  static final ModelDefinition<Author> definition = ModelDefinition<Author>(
    table: 'authors',
    factory: Author.new,
    fillable: ['name'],
    hidden: ['secret'],
    relations: {
      'books': () =>
          HasMany<Book>(() => Book.definition, foreignKey: 'author_id'),
    },
  );
  @override
  ModelDefinition<Author> get modelDefinition => Author.definition;
}

final class Book extends Model {
  static final ModelDefinition<Book> definition = ModelDefinition<Book>(
    table: 'books',
    factory: Book.new,
    softDeletes: true,
    casts: {'published_at': Cast.dateTime},
    relations: {
      'author': () =>
          BelongsTo<Author>(() => Author.definition, foreignKey: 'author_id'),
    },
  );
  @override
  ModelDefinition<Book> get modelDefinition => Book.definition;
}

final class CreateAuthors extends Migration {
  const CreateAuthors();
  @override
  String get name => '2026_01_01_000001_create_authors_table';
  @override
  Future<void> up(SchemaBuilder schema) => schema.create('authors', (t) {
    t.id();
    t.string('name');
  });
  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('authors');
}

final class Ping extends Job {
  const Ping();
  @override
  String get jobName => 'ping';
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) async {}
}

void main() {
  late Directory root;
  late Application app;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('daragic_export_');
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: shop\n');
    Directory(p.join(root.path, 'bootstrap')).createSync();
    File(p.join(root.path, '.env.example')).writeAsStringSync(
      'APP_NAME=Shop\nAPP_DEBUG=true\nAPP_PORT=8000\n'
      'APP_KEY=base64:should-not-leak\nDB_PASSWORD=hunter2\n',
    );
    app = Application.configure(basePath: root.path)
        .withEnv({
          'APP_ENV': 'local',
          'APP_NAME': 'Shop',
          'DB_DATABASE': p.join(root.path, 'shop.sqlite'),
        })
        .withModels([Author.definition, Book.definition])
        .withMigrations(const [CreateAuthors()])
        .withJobs([JobDefinition('ping', (_) => const Ping())])
        .withTranslations({
          'en': {
            'shop': {'welcome': 'Welcome'},
          },
        })
        .withSchedule((schedule) {
          schedule.command('cache:clear').dailyAt('03:00').withoutOverlapping();
          schedule.job(const Ping()).hourly().timezone('Asia/Jakarta');
        })
        .withRouting(
          api: (router) {
            router
                .post('/books', (_) => null)
                .rules(const {'title': 'required|string|max:120'})
                .returns(const {'type': 'object'}, name: 'Book')
                .action('BookController@store')
                .name('books.store')
                .middleware(const ['auth']);
            router.get('/books/{book}', (_) => null).whereNumber('book');
          },
        )
        .create();
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
    app.container.make<FeatureManager>().define('beta', (_) => true);
  });

  tearDown(() async {
    await app.shutdown();
    root.deleteSync(recursive: true);
  });

  test('routes, models and the rest of the DAM', () async {
    final dam = await buildDam(app);
    expect(dam['meta'], {
      'damVersion': '1.0',
      'source': {'framework': 'daravel', 'version': daravelVersion},
      'tool': 'dartisan daragic:export',
    });
    final routes = (dam['routes']! as List).cast<Map<String, Object?>>();
    final store = routes.firstWhere((r) => r['name'] == 'books.store');
    expect(store['uri'], 'api/books');
    expect(store['action'], {
      'class': 'BookController',
      'kind': 'controller',
      'method': 'store',
    });
    expect(store['middleware'], contains('auth'));
    expect(store['validation'], {
      'title': {
        'dsl': 'required|string|max:120',
        'rules': [
          {'name': 'required'},
          {'name': 'string'},
          {
            'name': 'max',
            'args': [120],
          },
        ],
      },
    });
    expect((store['response']! as Map)['name'], 'Book');
    final show = routes.firstWhere((r) => r['uri'] == 'api/books/{book}');
    expect(show['action'], {'kind': 'closure', 'unsupported': 'source'});
    // Laravel's unanchored form (whereNumber → [0-9]+).
    expect(show['where'], {'book': '[0-9]+'});

    final models = (dam['models']! as List).cast<Map<String, Object?>>();
    expect([for (final m in models) m['name']], ['Author', 'Book']);
    final book = models.last;
    expect(book['fqcn'], r'App\Models\Book');
    expect(book['softDeletes'], isTrue);
    expect(book['casts'], {'published_at': 'datetime'});
    expect(book['relations'], [
      {
        'foreignKey': 'author_id',
        'name': 'author',
        'ownerKey': 'id',
        'related': r'App\Models\Author',
        'type': 'belongsTo',
      },
    ]);
    expect(
      ((models.first['relations']! as List).single as Map)['type'],
      'hasMany',
    );

    expect(dam['migrations'], [
      {
        'batch': 1,
        'class': 'CreateAuthors',
        'name': '2026_01_01_000001_create_authors_table',
      },
    ]);
    final schema = (dam['schema']! as List).cast<Map<String, Object?>>();
    expect(
      [
        for (final c
            in schema.firstWhere((t) => t['name'] == 'authors')['columns']!
                as List)
          (c as Map)['name'],
      ],
      ['id', 'name'],
    );
    expect(dam['jobs'], [
      {'name': 'ping'},
    ]);
    expect(dam['features'], [
      {'name': 'beta'},
    ]);
    expect((dam['lang']! as Map)['lines'], {
      'en': {'shop.welcome': 'Welcome'},
    });
    final schedule = (dam['schedule']! as List).cast<Map<String, Object?>>();
    expect(schedule.first, containsPair('kind', 'command'));
    expect(schedule.first, containsPair('withoutOverlapping', true));
    expect(schedule.last, containsPair('job', 'ping'));
    expect(schedule.last, containsPair('timezone', 'Asia/Jakarta'));
    expect((dam['report']! as Map)['unsupported'], isNotEmpty);
  });

  test('no secrets: secret-looking env keys keep no default', () async {
    final env = ((await buildDam(app, only: {'env'}))['env']! as List)
        .cast<Map<String, Object?>>();
    expect(
      {for (final e in env) e['key']: e['default']},
      {
        'APP_DEBUG': 'true',
        'APP_KEY': null,
        'APP_NAME': 'Shop',
        'APP_PORT': '8000',
        'DB_PASSWORD': null,
      },
    );
    expect(env.firstWhere((e) => e['key'] == 'APP_KEY')['secret'], isTrue);
    expect(jsonEncode(env), isNot(contains('hunter2')));
  });

  test('deterministic: the same app exports the same bytes and lock', () async {
    final first = jsonEncode(await buildDam(app));
    final second = jsonEncode(await buildDam(app));
    expect(second, first);
    final dam = await buildDam(app);
    final lock = damLock(dam);
    expect(lock, damLock(await buildDam(app)));
    expect(
      (lock['entities']! as Map).keys,
      containsAll(['routes:POST api/books', 'models:Book', 'jobs:ping']),
    );
  });

  test(
    'daragic:export writes dam.json and daragic.lock; --only limits it',
    () async {
      final runner = DartisanRunner(() => app);
      expect(
        await runner.execute([
          'daragic:export',
          '--out=out',
          '--only=routes,models',
        ]),
        0,
      );
      final dam = jsonDecode(
        File(p.join(root.path, 'out', 'dam.json')).readAsStringSync(),
      ) as Map<String, Object?>;
      expect(dam.keys.toSet(), {'meta', 'routes', 'models', 'report'});
      expect(
        File(p.join(root.path, 'out', 'daragic.lock')).existsSync(),
        isTrue,
      );
      expect(await runner.execute(['daragic:export', '--only=nope']), 64);
    },
  );
}
