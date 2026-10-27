import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:daravel_teorion/daravel_teorion.dart';
import 'package:test/test.dart';

enum PostStatus { draft, published }

final class Author extends Model {
  static final ModelDefinition<Author> definition = ModelDefinition<Author>(
    table: 'authors',
    factory: Author.new,
    fillable: ['name'],
  );

  @override
  ModelDefinition<Author> get modelDefinition => Author.definition;
}

final class Comment extends Model {
  static final ModelDefinition<Comment> definition = ModelDefinition<Comment>(
    table: 'comments',
    factory: Comment.new,
    fillable: ['post_id', 'score'],
  );

  @override
  ModelDefinition<Comment> get modelDefinition => Comment.definition;
}

final class Post extends Model {
  static final ModelDefinition<Post> definition = ModelDefinition<Post>(
    table: 'posts',
    factory: Post.new,
    softDeletes: true,
    fillable: ['title', 'body', 'status', 'is_active', 'views', 'author_id'],
    hidden: ['body'],
    relations: {
      'author': () =>
          BelongsTo<Author>(() => Author.definition, foreignKey: 'author_id'),
      'comments': () =>
          HasMany<Comment>(() => Comment.definition, foreignKey: 'post_id'),
    },
    scopes: {
      'popular': (ModelQuery<Post> q, List<Object?> args) =>
          q.where('views', '>=', 100),
      // A scope that reads its own parameter from the request it is given.
      'byAuthor': (ModelQuery<Post> q, List<Object?> args) {
        final request = args.first! as Request;
        q.where('author_id', request.query['author_id']);
      },
    },
  );

  @override
  ModelDefinition<Post> get modelDefinition => Post.definition;

  String get title => getAttr('title');
}

final class PostQueryFilter extends QueryFilter<Post> {
  @override
  Map<String, Filter> get filters => {
    'search': Filter.multiLike(['title', 'body']).alias('q'),
    'status': Filter.enum_('status', PostStatus.values),
    'is_active': Filter.boolean(),
    'views': Filter.range(),
    'min_views': Filter.gt('views', true),
    'ids': Filter.in_('id'),
    'has_comments': Filter.has('comments'),
  };

  @override
  List<String> get allowedScopes => ['popular', 'byAuthor'];

  @override
  List<String> get allowedWiths => ['author'];

  @override
  Map<String, List<String>> get allowedWithColumns => {
    'author': ['name'],
  };

  @override
  List<String> get allowedWithCounts => ['comments'];

  @override
  Map<String, Map<String, List<String>>> get allowedAggregates => {
    'comments': {
      'sum': ['score'],
      'count': [],
    },
  };

  @override
  List<String> get allowedSorts => ['id', 'title', 'views'];

  @override
  List<String> get defaultSort => ['-id'];
}

/// The same filter, letting a client see the hidden `body`.
final class OpenPostQueryFilter extends PostQueryFilter {
  @override
  List<String> get allowedVisibles => ['body'];
}

final class CreateTables extends Migration {
  const CreateTables();

  @override
  String get name => '2026_01_01_000000_create_tables';

  @override
  Future<void> up(SchemaBuilder schema) async {
    await schema.create('authors', (t) {
      t.id();
      t.string('name');
      t.timestamps();
    });
    await schema.create('posts', (t) {
      t.id();
      t.string('title');
      t.text('body');
      t.string('status');
      t.boolean('is_active');
      t.integer('views');
      t.unsignedBigInteger('author_id');
      t.timestamps();
      t.softDeletes();
    });
    await schema.create('comments', (t) {
      t.id();
      t.unsignedBigInteger('post_id');
      t.integer('score');
      t.timestamps();
    });
  }

  @override
  Future<void> down(SchemaBuilder schema) async {}
}

/// SQLite always; PostgreSQL and MySQL / MariaDB with `DARAVEL_TEST_PG` and
/// `DARAVEL_TEST_MYSQL`.
void main() {
  group('sqlite', teorionTests);
  final pg = Platform.environment['DARAVEL_TEST_PG'];
  if (pg != null && pg.isNotEmpty) {
    group('pgsql', () => teorionTests(databaseUrl: pg), tags: 'integration');
  }
  final mysql = Platform.environment['DARAVEL_TEST_MYSQL'];
  if (mysql != null && mysql.isNotEmpty) {
    group('mysql', () => teorionTests(databaseUrl: mysql), tags: 'integration');
  }
}

void teorionTests({String? databaseUrl}) {
  late Directory dir;
  late Application app;
  Map<String, String> database() => databaseUrl == null
      ? {'DB_DATABASE': '${dir.path}/app.sqlite'}
      : {'DB_URL': databaseUrl};

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('daravel_teorion_');
    app = Application.configure(basePath: dir.path)
        .withQueryFilters({Post: PostQueryFilter.new})
        .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
        .withEnv({
          'APP_ENV': 'testing',
          ...database(),
          'TEORION_STRICT': 'false',
        })
        .withMigrations(const [CreateTables()])
        .create();
    await app.boot();
    await app.run(() async {
      if (databaseUrl != null) {
        final schema = await Schema.builder();
        for (final table in ['comments', 'posts', 'authors']) {
          await schema.dropIfExists(table);
        }
        if (await schema.hasTable('migrations')) {
          await DB
              .table('migrations')
              .where('migration', const CreateTables().name)
              .delete();
        }
      }
      await App.make<Migrator>().run();
      final ana = await Author.definition.query().create({'name': 'Ana'});
      final bo = await Author.definition.query().create({'name': 'Bo'});
      final rows = [
        ('Dart tips', 'published', true, 150, ana),
        ('Laravel notes', 'draft', true, 20, ana),
        ('Daravel launch', 'published', false, 300, bo),
        ('Old post', 'published', true, 5, bo),
      ];
      for (final (title, status, active, views, author) in rows) {
        await Post.definition.query().create({
          'title': title,
          'body': 'About $title',
          'status': status,
          'is_active': active,
          'views': views,
          'author_id': author.key,
        });
      }
      await Comment.definition.query().create({'post_id': 1, 'score': 4});
      await Comment.definition.query().create({'post_id': 1, 'score': 5});
      final old = await Post.definition
          .query()
          .where('title', 'Old post')
          .first();
      await old!.delete();
    });
  });

  tearDown(() async {
    await app.shutdown();
    dir.deleteSync(recursive: true);
  });

  /// The titles of `GET /posts?<query>`, filtered.
  Future<Object> list(String query, [QueryFilter<Post>? filter]) => app.run(
    () => Post.definition.query().filterAndPaginate(
      Request.fake(path: '/posts?$query'),
      filter,
    ),
  );

  Future<List<String>> titles(String query) async {
    final result = await list(query);
    final items = switch (result) {
      final ModelCollection<Post> all => all,
      final LengthAwarePaginator<Post> page => page.items,
      final CursorPaginator<Post> page => page.items,
      _ => throw StateError('$result'),
    };
    return [for (final post in items) post.title];
  }

  test('without parameters: every row, the default sort, no paging', () async {
    expect(await titles(''), ['Daravel launch', 'Laravel notes', 'Dart tips']);
    expect(await list(''), isA<ModelCollection<Post>>());
  });

  test('declared filters, aliases and enums', () async {
    expect(await titles('q=Laravel'), ['Laravel notes']);
    expect(
      await titles('search=Laravel'),
      isNot(['Laravel notes']),
      reason: 'the alias replaces the name',
    );
    expect(await titles('status=draft'), ['Laravel notes']);
    expect(await titles('status=bogus'), isEmpty);
    expect(await titles('is_active=0'), ['Daravel launch']);
    expect(await titles('views_min=100&views_max=200'), ['Dart tips']);
    expect(await titles('min_views=150'), ['Daravel launch', 'Dart tips']);
    expect(await titles('ids=1,3'), ['Daravel launch', 'Dart tips']);
    expect(await titles('ids[]=2'), ['Laravel notes']);
    expect(await titles('has_comments=1'), ['Dart tips']);
    expect(await titles('has_comments=0'), ['Daravel launch', 'Laravel notes']);
  });

  test('sorts: Spatie style, the legacy formats, and the whitelist', () async {
    expect(await titles('sort=title'), [
      'Daravel launch',
      'Dart tips',
      'Laravel notes',
    ]);
    expect(await titles('sort=-views,title'), [
      'Daravel launch',
      'Dart tips',
      'Laravel notes',
    ]);
    expect(await titles('order_by=views&order_direction=asc'), [
      'Laravel notes',
      'Dart tips',
      'Daravel launch',
    ]);
    expect(await titles('order[0][by]=views&order[0][direction]=desc'), [
      'Daravel launch',
      'Dart tips',
      'Laravel notes',
    ]);
    await expectLater(
      list('sort=body'),
      throwsA(
        isA<DisallowedSortException>()
            .having((e) => e.status, 'status', 400)
            .having(
              (e) => e.message,
              'message',
              'Sort column [body] is not in the allowed sorts list.',
            ),
      ),
    );
    // laravel-teorion interpolates this into SQL; here it must be allowed.
    await expectLater(
      list('order_null_bottoms[]=id);DROP TABLE posts;--'),
      throwsA(isA<DisallowedSortException>()),
    );
    expect(await titles('order_null_bottoms[]=views&sort=views'), [
      'Laravel notes',
      'Dart tips',
      'Daravel launch',
    ]);
  });

  test('scopes: legacy, isolated parameters, and the whitelist', () async {
    expect(await titles('scopes[]=popular'), ['Daravel launch', 'Dart tips']);
    expect(
      await titles('scopes[0][name]=byAuthor&scopes[0][params][author_id]=2'),
      ['Daravel launch'],
    );
    // `params` that is not a map is a client's mistake, read as none, not
    // a 500.
    expect(await titles('scopes[0][name]=popular&scopes[0][params]=x'), [
      'Daravel launch',
      'Dart tips',
    ]);
    await expectLater(
      list('scopes[]=secret'),
      throwsA(
        isA<DisallowedScopeException>().having(
          (e) => e.message,
          'message',
          'Scope [secret] is not in the allowed scopes list.',
        ),
      ),
    );
  });

  test('relations, counts and aggregates within their whitelists', () async {
    final posts = await list(
      'withs[]=author&withs[]=comments&withCounts[]=comments'
      '&withAggregates[comments][sum][]=score&sort=id',
    ) as ModelCollection<Post>;
    final first = posts.first.toJson();
    expect((first['author']! as Map)['name'], 'Ana');
    expect(
      first.containsKey('comments'),
      isFalse,
      reason: 'not in allowedWiths',
    );
    expect(first['comments_count'], 2);
    // MySQL returns SUM as DECIMAL text, as Laravel reads it.
    expect(num.parse('${first['comments_sum_score']}'), 9);
    // Listed columns only, plus the key the relation matches on.
    final picked =
        await list('withs[]=author:name&sort=id') as ModelCollection<Post>;
    expect(picked.first.toJson()['author'], {'name': 'Ana', 'id': 1});
    // Anything else is not loaded: an unlisted column, an expression, or
    // columns of a relation without a list.
    for (final refused in [
      'withs[]=author:name,created_at',
      'withs[]=author:(select 1)',
      'withs[]=author:',
    ]) {
      final posts = await list(refused) as ModelCollection<Post>;
      expect(
        posts.first.toJson().containsKey('author'),
        isFalse,
        reason: refused,
      );
    }
    // `author` in the list opens `author` only: a nested path is checked
    // whole, so neither a deeper relation nor one the model does not even
    // define (which would be a 500 from the loader) is reached.
    for (final nested in [
      'withs[]=author.comments',
      'withs[]=author.nothing.deeper',
      'withs[]=author.nothing:name',
    ]) {
      final posts = await list('$nested&sort=id') as ModelCollection<Post>;
      expect(
        posts.first.toJson().containsKey('author'),
        isFalse,
        reason: nested,
      );
    }
  });

  test('strict mode refuses relations outside the whitelist', () async {
    await app.shutdown();
    app = Application.configure(basePath: dir.path)
        .withQueryFilters({Post: PostQueryFilter.new})
        .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
        .withEnv({
          'APP_ENV': 'testing',
          ...database(),
          'TEORION_STRICT': 'true',
        })
        .create();
    await app.boot();
    await expectLater(
      list('withs[]=comments'),
      throwsA(
        isA<DisallowedWithException>().having(
          (e) => e.message,
          'message',
          'Relation [comments] is not in the allowed withs list.',
        ),
      ),
    );
    await expectLater(
      list('withs[]=author:created_at'),
      throwsA(
        isA<DisallowedWithColumnsException>()
            .having((e) => e.status, 'status', 400)
            .having(
              (e) => e.message,
              'message',
              'Column [created_at] of relation [author] is not in the '
                  'allowed with columns list.',
            ),
      ),
    );
    await expectLater(
      list('withs[]=author.comments'),
      throwsA(
        isA<DisallowedWithException>().having(
          (e) => e.message,
          'message',
          'Relation [author.comments] is not in the allowed withs list.',
        ),
      ),
    );
    await expectLater(
      list('visibles[]=body'),
      throwsA(
        isA<DisallowedVisibleException>()
            .having((e) => e.status, 'status', 400)
            .having(
              (e) => e.message,
              'message',
              'Attribute [body] is not in the allowed visibles list.',
            ),
      ),
    );
  });

  test('pagination: is_paginate, per_page, max_results, cursor', () async {
    final page =
        await list('is_paginate=1&per_page=2') as LengthAwarePaginator<Post>;
    expect(page.total, 3);
    expect(page.items, hasLength(2));
    final limited = await titles('max_results=1');
    expect(limited, ['Daravel launch']);
    final cursor =
        await list('pagination=cursor&per_page=2') as CursorPaginator<Post>;
    expect(cursor.items, hasLength(2));
    expect(cursor.nextCursor, isNotNull);
  });

  test(
    'per_page and max_results are clamped to TEORION_MAX_PER_PAGE',
    () async {
      await app.shutdown();
      app = Application.configure(basePath: dir.path)
          .withQueryFilters({Post: PostQueryFilter.new})
          .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
          .withEnv({
            'APP_ENV': 'testing',
            ...database(),
            'TEORION_DEFAULT_PER_PAGE': '1',
            'TEORION_MAX_PER_PAGE': '2',
          })
          .create();
      await app.boot();
      expect(
        App.make<ConfigRepository>()
            .section<TeorionConfig>()
            .toMap()['max_per_page'],
        2,
      );
      // Above the cap: cut to it, not the whole table.
      expect(await titles('max_results=100000000'), hasLength(2));
      expect(await titles('is_paginate=1&per_page=1000'), hasLength(2));
      // Below 1 is not a size: the default, not "no limit" (which is how the
      // builder reads a negative limit) and not a division by zero in the
      // paginator.
      expect(await titles('max_results=-1'), hasLength(1));
      expect(await titles('per_page=0'), hasLength(1));
      final page =
          await list('is_paginate=1&per_page=0') as LengthAwarePaginator<Post>;
      expect(page.items, hasLength(1));
      expect(page.lastPage, 3);
      expect(await titles('pagination=cursor&per_page=-5'), hasLength(1));
    },
  );

  test('soft deletes, visibles and hiddens', () async {
    expect(await titles('with_trashed=1'), contains('Old post'));
    expect(await titles('only_trashed=1'), ['Old post']);
    // A hidden attribute is shown only when the filter lists it in
    // allowedVisibles; PostQueryFilter lists none, so `body` stays hidden.
    final kept = await list('visibles[]=body&sort=id') as ModelCollection<Post>;
    expect(kept.first.toJson().containsKey('body'), isFalse);
    final shown = await list(
      'visibles[]=body&sort=id',
      OpenPostQueryFilter(),
    ) as ModelCollection<Post>;
    expect(shown.first.toJson()['body'], 'About Dart tips');
    final one = await app.run(
      () => Post.definition.query().findFiltered(
        Request.fake(path: '/posts?visibles[]=body'),
        1,
        OpenPostQueryFilter(),
      ),
    );
    expect(one!.toJson()['body'], 'About Dart tips');
    final hidden = await list('hiddens[]=title') as ModelCollection<Post>;
    expect(hidden.first.toJson().containsKey('title'), isFalse);
  });

  test('findFiltered, explicit filters and missing registrations', () async {
    await app.run(() async {
      final post = await Post.definition.query().findFiltered(
        Request.fake(path: '/posts/1?withs[]=author'),
        1,
      );
      expect(post!.title, 'Dart tips');
      expect((post.toJson()['author']! as Map)['name'], 'Ana');
      await expectLater(
        Comment.definition.query().filter(Request.fake()),
        throwsA(isA<QueryFilterNotFoundException>()),
      );
    });
  });

  test('a required filter, and the audit with its fingerprint', () async {
    await app.shutdown();
    final audits = <QueryAudited>[];
    app = Application.configure(basePath: dir.path)
        .withQueryFilters({Post: PostQueryFilter.new})
        .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
        .withEvents((events) => events.listen<QueryAudited>(audits.add))
        .withEnv({
          'APP_ENV': 'testing',
          ...database(),
          'TEORION_AUDIT_ENABLED': 'true',
        })
        .create();
    await app.boot();
    await list('status=published&sort=id');
    await list('sort=id&status=published&page=3');
    expect(audits, hasLength(2));
    final first = audits.first.record;
    expect(first['terminal_mode'], 'collection');
    expect(first['result_count'], 2);
    expect(
      (first['fingerprint']! as Map)['hash'],
      (audits.last.record['fingerprint']! as Map)['hash'],
      reason: 'parameter order and page do not change the intent',
    );

    await app.run(() async {
      await expectLater(
        Post.definition.query().filter(Request.fake(), _RequiredFilter()),
        throwsA(
          isA<RequiredFilterMissingException>().having(
            (e) => e.message,
            'message',
            'Required filter parameter [tenant] is missing from the request.',
          ),
        ),
      );
    });
  });

  test('validation rules and OpenAPI parameters', () {
    final rules = PostQueryFilter().validationRules;
    expect(rules['status'], 'nullable|in:draft,published');
    expect(rules['q'], 'nullable|string|max:255');
    expect(rules['per_page'], 'nullable|integer|min:1|max:100');
    final names = [
      for (final p in PostQueryFilter().openApiParameters) p['name'],
    ];
    expect(
      names,
      containsAll(['q', 'status', 'sort', 'withs[]', 'is_paginate']),
    );
    final withs = PostQueryFilter().openApiParameters.firstWhere(
      (p) => p['name'] == 'withs[]',
    );
    expect(withs['description'], contains('author (name)'));
  });
}

final class _RequiredFilter extends QueryFilter<Post> {
  @override
  Map<String, Filter> get filters => {'tenant': Filter.exact().required()};
}
