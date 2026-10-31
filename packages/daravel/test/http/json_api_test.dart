import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class Author extends Model {
  static final ModelDefinition<Author> definition = ModelDefinition<Author>(
    table: 'authors',
    factory: Author.new,
    timestamps: false,
    relations: {
      'articles': () =>
          HasMany<Article>(() => Article.definition, foreignKey: 'author_id'),
    },
  );
  @override
  ModelDefinition<Author> get modelDefinition => definition;
}

final class Article extends Model {
  static final ModelDefinition<Article> definition = ModelDefinition<Article>(
    table: 'articles',
    factory: Article.new,
    timestamps: false,
    relations: {
      'author': () =>
          BelongsTo<Author>(() => Author.definition, foreignKey: 'author_id'),
      'comments': () =>
          HasMany<Note>(() => Note.definition, foreignKey: 'article_id'),
      'labels': () => BelongsToMany<Label>(
        () => Label.definition,
        pivotTable: 'article_label',
        foreignPivotKey: 'article_id',
        relatedPivotKey: 'label_id',
      ),
    },
  );
  @override
  ModelDefinition<Article> get modelDefinition => definition;
}

final class Note extends Model {
  static final ModelDefinition<Note> definition = ModelDefinition<Note>(
    table: 'notes',
    factory: Note.new,
    timestamps: false,
    relations: {
      'author': () =>
          BelongsTo<Author>(() => Author.definition, foreignKey: 'author_id'),
    },
  );
  @override
  ModelDefinition<Note> get modelDefinition => definition;
}

final class Label extends Model {
  static final ModelDefinition<Label> definition = ModelDefinition<Label>(
    table: 'labels',
    factory: Label.new,
    timestamps: false,
  );
  @override
  ModelDefinition<Label> get modelDefinition => definition;
}

final class AuthorResource extends JsonApiResource<Author> {
  AuthorResource(super.resource);

  @override
  String toType(Request? request) => 'authors';

  @override
  Map<String, Object?> toArray(Request? request) => {
    'name': resource.getAttr<String>('name'),
  };
}

final class NoteResource extends JsonApiResource<Note> {
  NoteResource(super.resource);

  @override
  String toType(Request? request) => 'notes';

  @override
  Map<String, Object?> toArray(Request? request) => {
    'body': resource.getAttr<String>('body'),
  };

  @override
  Map<String, JsonApiRelationship<Model>> toRelationships(Request? request) => {
    'author': JsonApiRelationship<Author>(AuthorResource.new),
  };
}

final class LabelResource extends JsonApiResource<Label> {
  LabelResource(super.resource);

  @override
  String toType(Request? request) => 'labels';

  @override
  Map<String, Object?> toArray(Request? request) => {
    'name': resource.getAttr<String>('name'),
  };
}

final class ArticleResource extends JsonApiResource<Article> {
  ArticleResource(super.resource);

  @override
  String toType(Request? request) => 'articles';

  @override
  Map<String, Object?> toArray(Request? request) => {
    'title': resource.getAttr<String>('title'),
    'body': resource.getAttr<String>('body'),
    'hidden': when(false, () => 'x'),
  };

  @override
  Map<String, JsonApiRelationship<Model>> toRelationships(Request? request) => {
    'author': JsonApiRelationship<Author>(AuthorResource.new),
    'comments': JsonApiRelationship<Note>(NoteResource.new),
    'labels': JsonApiRelationship<Label>(LabelResource.new),
  };

  @override
  Map<String, Object?> toLinks(Request? request) => {
    'self': '/articles/${resource.key}',
  };

  @override
  Map<String, Object?> toMeta(Request? request) => {'views': 3};
}

final class PlainResource extends JsonApiResource<Map<String, Object?>> {
  PlainResource(super.resource);

  @override
  String toType(Request? request) => 'plains';

  @override
  String? toId(Request? request) => '${resource['id']}';

  @override
  Map<String, Object?> toArray(Request? request) => resource;
}

void main() {
  late Directory base;
  late Application app;

  Future<Map<String, Object?>> get(String uri) async {
    final parsed = Uri.parse(uri);
    final response = await app.handle(
      Request.fake(path: parsed.path, query: parsed.queryParameters),
    );
    expect(response.status, 200);
    expect(response.headers['content-type'], 'application/vnd.api+json');
    return jsonDecode(utf8.decode(await response.bodyBytes()))
        as Map<String, Object?>;
  }

  setUp(() async {
    base = Directory.systemTemp.createTempSync('daravel_json_api');
    app = Application.configure(basePath: base.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          web: (router) {
            router
              ..get('/articles', (Request request) async {
                final page = await Article.definition
                    .query()
                    .orderBy('id')
                    .get();
                return JsonApiResource.collection<Article>(
                  page.toList(),
                  ArticleResource.new,
                );
              })
              ..get('/paged', (Request request) async {
                final page = await Article.definition
                    .query()
                    .orderBy('id')
                    .paginate(perPage: 1);
                return JsonApiResource.collection<Article>(
                  page,
                  ArticleResource.new,
                );
              })
              ..get('/one', (Request request) async {
                final article = await Article.definition.query().find(1);
                return ArticleResource(article!);
              });
          },
        )
        .create();
    await app.boot();
    await app.run(() async {
      for (final sql in const [
        'CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT)',
        'CREATE TABLE articles (id INTEGER PRIMARY KEY, title TEXT, body TEXT, '
            'author_id INTEGER)',
        'CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT, '
            'article_id INTEGER, author_id INTEGER)',
        'CREATE TABLE labels (id INTEGER PRIMARY KEY, name TEXT)',
        'CREATE TABLE article_label (article_id INTEGER, label_id INTEGER)',
      ]) {
        await DB.statement(sql);
      }
      await DB.table('authors').insert([
        {'id': 1, 'name': 'Ana'},
        {'id': 2, 'name': 'Budi'},
      ]);
      await DB.table('articles').insert([
        {'id': 1, 'title': 'One', 'body': 'b1', 'author_id': 1},
        {'id': 2, 'title': 'Two', 'body': 'b2', 'author_id': 1},
      ]);
      await DB.table('notes').insert([
        {'id': 1, 'body': 'n1', 'article_id': 1, 'author_id': 2},
        {'id': 2, 'body': 'n2', 'article_id': 1, 'author_id': 1},
      ]);
      await DB.table('labels').insert([
        {'id': 1, 'name': 'dart'},
      ]);
      await DB.table('article_label').insert([
        {'article_id': 1, 'label_id': 1},
        {'article_id': 2, 'label_id': 1},
      ]);
    });
  });

  tearDown(() async {
    JsonApiResource.jsonApiInformation = const {};
    JsonApiResource.maxRelationshipDepth(5);
    await app.shutdown();
    base.deleteSync(recursive: true);
  });

  test('a resource object, with no relationships unless asked', () async {
    expect(await get('/one'), {
      'data': {
        'id': '1',
        'type': 'articles',
        'attributes': {'title': 'One', 'body': 'b1'},
        'links': {'self': '/articles/1'},
        'meta': {'views': 3},
      },
    });
  });

  test('members keep Laravel\'s order', () async {
    final data = (await get('/one?include=author'))['data']! as Map;
    expect(data.keys, [
      'id',
      'type',
      'attributes',
      'relationships',
      'links',
      'meta',
    ]);
  });

  test('fields narrow the attributes of a type', () async {
    final body = await get('/one?fields[articles]=title');
    expect((body['data']! as Map)['attributes'], {'title': 'One'});
  });

  test('empty fields leave no attributes', () async {
    final body = await get('/one?fields[articles]=');
    expect((body['data']! as Map).containsKey('attributes'), isFalse);
  });

  test('fields reach included objects by their type', () async {
    final body = await get('/one?include=comments&fields[notes]=id');
    expect((body['included']! as List).first, {'id': '1', 'type': 'notes'});
  });

  test('include loads the relation and identifies it', () async {
    final body = await get('/one?include=author');
    expect((body['data']! as Map)['relationships'], {
      'author': {
        'data': {'id': '1', 'type': 'authors'},
      },
    });
    expect(body['included'], [
      {
        'id': '1',
        'type': 'authors',
        'attributes': {'name': 'Ana'},
      },
    ]);
  });

  test('an unknown include is ignored', () async {
    final body = await get('/one?include=nothing');
    expect(body.containsKey('included'), isFalse);
    expect((body['data']! as Map).containsKey('relationships'), isFalse);
  });

  test('nested includes load, and included carries identifiers', () async {
    final body = await get('/one?include=comments.author');
    final included = (body['included']! as List).cast<Map<String, Object?>>();
    expect(
      [for (final i in included) '${i['type']}:${i['id']}'],
      ['notes:1', 'notes:2', 'authors:2', 'authors:1'],
    );
    expect(included.first['relationships'], {
      'author': {
        'data': {'id': '2', 'type': 'authors'},
      },
    });
  });

  test('included holds each object once', () async {
    final body = await get('/articles?include=author');
    expect((body['included']! as List).length, 1);
    final data = (body['data']! as List).cast<Map<String, Object?>>();
    expect(data, hasLength(2));
  });

  test('BelongsToMany rows stay, for their pivot data', () async {
    final body = await get('/articles?include=labels');
    expect((body['included']! as List).length, 2);
  });

  test('a collection loads a page in one query per relation', () async {
    final count = await app.run(() async {
      final (_, queries) = await DB.manager.captureQueries(() async {
        await get('/articles?include=author,comments.author');
      });
      return queries.length;
    });
    expect(count, 4, reason: 'articles, authors, notes, their authors');
  });

  test('an empty relation is an empty list', () async {
    final body = await get('/articles?include=comments');
    final second = (body['data']! as List)[1] as Map<String, Object?>;
    expect(second['relationships'], {
      'comments': {'data': <Object?>[]},
    });
  });

  test('a missing to-one relation is null', () async {
    await app.run(
      () => DB.table('articles').where('id', 1).update({'author_id': null}),
    );
    final body = await get('/one?include=author');
    expect((body['data']! as Map)['relationships'], {
      'author': {'data': null},
    });
    expect(body.containsKey('included'), isFalse);
  });

  test('a paginator adds links and meta', () async {
    final body = await get('/paged');
    expect(body.keys, ['data', 'links', 'meta']);
    expect((body['meta']! as Map)['total'], 2);
    expect(body['links'], contains('next'));
  });

  test('configure adds the jsonapi member', () async {
    JsonApiResource.configure(version: '1.1', ext: ['atomic']);
    expect((await get('/one'))['jsonapi'], {
      'version': '1.1',
      'ext': ['atomic'],
    });
  });

  test('depth limits include', () async {
    JsonApiResource.maxRelationshipDepth(1);
    final body = await get('/one?include=comments.author');
    final types = {
      for (final i in (body['included']! as List).cast<Map<String, Object?>>())
        i['type'],
    };
    expect(types, {'notes'});
  });

  test('outside a route, what is not loaded is left out', () async {
    await app.run(() async {
      final article = await Article.definition.query().find(1);
      final request = Request.fake(query: {'include': 'author'});
      final payload = ArticleResource(article!).toPayload(request);
      expect(payload.containsKey('included'), isFalse);
    });
  });

  test('a resource without a model needs toId', () {
    final payload = PlainResource(const {'id': 7, 'a': 1}).toPayload();
    expect((payload['data']! as Map)['id'], '7');
  });

  test('additional data goes next to data', () async {
    await app.run(() async {
      final article = await Article.definition.query().find(1);
      final payload = ArticleResource(article!)
          .additional({'extra': true})
          .toPayload();
      expect(payload['extra'], isTrue);
    });
  });
}
