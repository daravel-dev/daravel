import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class Author extends Model {
  static final ModelDefinition<Author> definition = ModelDefinition<Author>(
    table: 'authors',
    factory: Author.new,
    fillable: ['name', 'secret'],
    relations: {
      'books': () =>
          HasMany<Book>(() => Book.definition, foreignKey: 'author_id'),
    },
  );

  @override
  ModelDefinition<Author> get modelDefinition => Author.definition;

  int get id => getAttr('id');
  String get name => getAttr('name');
}

final class Book extends Model {
  static final ModelDefinition<Book> definition = ModelDefinition<Book>(
    table: 'books',
    factory: Book.new,
    fillable: ['title', 'author_id'],
  );

  @override
  ModelDefinition<Book> get modelDefinition => Book.definition;

  String get title => getAttr('title');
}

final class BookResource extends JsonResource<Book> {
  BookResource(super.resource);

  @override
  Map<String, Object?> toArray(Request? request) => {'title': resource.title};
}

final class AuthorResource extends JsonResource<Author> {
  AuthorResource(super.resource);

  @override
  Map<String, Object?> toArray(Request? request) => {
    'id': resource.id,
    'name': resource.name,
    'admin_note': when(request?.query['admin'] == '1', () => 'vip'),
    'nickname': whenNotNull(null),
    'books': whenLoaded(
      'books',
      (books) =>
          JsonResource.collection(books! as List<Book>, BookResource.new),
    ),
    'extra': mergeWhen(resource.id == 1, () => {'first': true}),
  };

  @override
  Map<String, Object?> withMeta(Request? request) => {'version': '1.0'};
}

final class CreateTables extends Migration {
  const CreateTables();
  @override
  String get name => '2026_01_01_000000_create_authors';
  @override
  Future<void> up(SchemaBuilder schema) async {
    await schema.create('authors', (t) {
      t.id();
      t.string('name');
      t.string('secret').nullable();
      t.timestamps();
    });
    await schema.create('books', (t) {
      t.id();
      t.foreignId('author_id');
      t.string('title');
      t.timestamps();
    });
  }

  @override
  Future<void> down(SchemaBuilder schema) async {}
}

void main() {
  late Application app;

  setUp(() async {
    ResourceWrapping.wrap('data');
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withMigrations(const [CreateTables()])
        .create();
    await app.boot();
    await app.run(() async {
      await App.make<Migrator>().run();
      for (var i = 1; i <= 3; i++) {
        final author = await Author.definition.query().create({'name': 'A$i'});
        await Book.definition.query().create({
          'title': 'B$i',
          'author_id': author.id,
        });
      }
    });
  });

  tearDown(() async {
    ResourceWrapping.wrap('data');
    await app.shutdown();
  });

  Future<Map<String, Object?>> body(Response response) async =>
      jsonDecode(await response.bodyText()) as Map<String, Object?>;

  test(
    'single resource: wrapping, conditionals, merge, meta, additional',
    () async {
      await app.run(() async {
        final author = (await Author.definition.query().find(1))!;
        final plain = await body(
          AuthorResource(author)
              .additional({'trace': 'x'})
              .toResponse(Request.fake()),
        );
        expect(plain, {
          'data': {'id': 1, 'name': 'A1', 'first': true},
          'version': '1.0',
          'trace': 'x',
        });

        final loaded = (await Author.definition
            .query()
            .with_(['books'])
            .find(1))!;
        final admin = await body(
          AuthorResource(loaded)
              .toResponse(Request.fake(query: {'admin': '1'})),
        );
        expect((admin['data']! as Map)['admin_note'], 'vip');
        expect((admin['data']! as Map)['books'], [
          {'title': 'B1'},
        ]);

        ResourceWrapping.disable();
        final bare = await body(
          AuthorResource(author).toResponse(Request.fake()),
        );
        expect(bare['name'], 'A1');
        expect(bare.containsKey('data'), isFalse);
      });
    },
  );

  test(
    'freshly created models answer 201; nested in maps they resolve',
    () async {
      await app.run(() async {
        final created = await Author.definition.query().create({'name': 'New'});
        expect(AuthorResource(created).toResponse(Request.fake()).status, 201);
        expect(
          AuthorResource(created)
              .withStatus(202)
              .toResponse(Request.fake())
              .status,
          202,
        );
        final nested = jsonDecode(
          await Response.json({'author': AuthorResource(created)}).bodyText(),
        );
        expect(nested, {
          'author': {'id': 4, 'name': 'New'},
        });
      });
    },
  );

  test('collections: plain list and every paginator flavour', () async {
    await app.run(() async {
      final all = await Author.definition.query().get();
      final list = JsonResource.collection(all, AuthorResource.new);
      expect(
        ((await body(list.toResponse(Request.fake())))['data']! as List).length,
        3,
      );

      final page = await Author.definition.query().paginate(
        perPage: 2,
        path: '/authors',
      );
      final paged = await body(
        JsonResource.collection(
          page,
          AuthorResource.new,
        ).toResponse(Request.fake()),
      );
      expect((paged['data']! as List).length, 2);
      expect(paged['links'], {
        'first': '/authors?page=1',
        'last': '/authors?page=2',
        'prev': null,
        'next': '/authors?page=2',
      });
      final meta = paged['meta']! as Map<String, Object?>;
      expect(meta['total'], 3);
      expect(meta['last_page'], 2);
      expect(meta['from'], 1);
      expect(meta['to'], 2);
      expect(meta['links'], isA<List<Object?>>());

      final simple = await Author.definition.query().simplePaginate(
        perPage: 2,
        path: '/a',
      );
      final simpleBody = await body(
        JsonResource.collection(
          simple,
          AuthorResource.new,
        ).toResponse(Request.fake()),
      );
      expect((simpleBody['links']! as Map)['next'], '/a?page=2');
      expect((simpleBody['meta']! as Map).containsKey('total'), isFalse);

      final cursor = await Author.definition
          .query()
          .orderBy('id')
          .cursorPaginate(perPage: 2, path: '/c');
      final cursorBody = await body(
        JsonResource.collection(
          cursor,
          AuthorResource.new,
        ).toResponse(Request.fake()),
      );
      expect((cursorBody['meta']! as Map)['next_cursor'], isNotNull);
      expect((cursorBody['links']! as Map)['next'], startsWith('/c?cursor='));

      ResourceWrapping.disable();
      final bare = jsonDecode(await list.toResponse(Request.fake()).bodyText());
      expect(bare, isA<List<Object?>>());
      expect(
        () => ResourceCollection<Author>('nope', AuthorResource.new),
        throwsArgumentError,
      );
    });
  });
}
