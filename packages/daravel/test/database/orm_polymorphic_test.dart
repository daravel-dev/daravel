import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import 'support/test_databases.dart';

// ---------------------------------------------------------------------------
// Models: posts and videos share comments (morphMany), images (morphOne)
// and tags (morphToMany through `taggables`).
// ---------------------------------------------------------------------------

final class User extends Model {
  static final ModelDefinition<User> definition = ModelDefinition<User>(
    table: 'users',
    factory: User.new,
    guarded: [],
    timestamps: false,
    relations: {
      'posts': () =>
          HasMany<Post>(() => Post.definition, foreignKey: 'user_id'),
    },
  );
  @override
  ModelDefinition<User> get modelDefinition => User.definition;
  String get name => getAttr('name');
}

final class Post extends Model {
  static final ModelDefinition<Post> definition = ModelDefinition<Post>(
    table: 'posts',
    factory: Post.new,
    guarded: [],
    softDeletes: true,
    relations: {
      'author': () =>
          BelongsTo<User>(() => User.definition, foreignKey: 'user_id'),
      'comments': () => MorphMany<Comment>(
        () => Comment.definition,
        morphName: 'commentable',
      ),
      'image': () =>
          MorphOne<Image>(() => Image.definition, morphName: 'imageable'),
      'tags': () => MorphToMany<Tag>(
        () => Tag.definition,
        morphName: 'taggable',
        relatedPivotKey: 'tag_id',
      ),
    },
  );
  @override
  ModelDefinition<Post> get modelDefinition => Post.definition;
  int get id => getAttr('id');
  String get title => getAttr('title');
}

final class Video extends Model {
  static final ModelDefinition<Video> definition = ModelDefinition<Video>(
    table: 'videos',
    factory: Video.new,
    guarded: [],
    timestamps: false,
    relations: {
      'author': () =>
          BelongsTo<User>(() => User.definition, foreignKey: 'user_id'),
      'comments': () => MorphMany<Comment>(
        () => Comment.definition,
        morphName: 'commentable',
      ),
      'tags': () => MorphToMany<Tag>(
        () => Tag.definition,
        morphName: 'taggable',
        relatedPivotKey: 'tag_id',
      ),
    },
  );
  @override
  ModelDefinition<Video> get modelDefinition => Video.definition;
  int get id => getAttr('id');
  String get title => getAttr('title');
}

final class Comment extends Model {
  static final ModelDefinition<Comment> definition = ModelDefinition<Comment>(
    table: 'comments',
    factory: Comment.new,
    guarded: [],
    timestamps: false,
    touches: ['commentable'],
    relations: {
      // morphName defaults to the registered name.
      'commentable': () =>
          MorphTo(types: [() => Post.definition, () => Video.definition]),
      'reactions': () => HasMany<Reaction>(
        () => Reaction.definition,
        foreignKey: 'comment_id',
      ),
    },
  );
  @override
  ModelDefinition<Comment> get modelDefinition => Comment.definition;
  String get body => getAttr('body');
}

final class Reaction extends Model {
  static final ModelDefinition<Reaction> definition = ModelDefinition<Reaction>(
    table: 'reactions',
    factory: Reaction.new,
    guarded: [],
    timestamps: false,
  );
  @override
  ModelDefinition<Reaction> get modelDefinition => Reaction.definition;
}

final class Image extends Model {
  static final ModelDefinition<Image> definition = ModelDefinition<Image>(
    table: 'images',
    factory: Image.new,
    guarded: [],
    timestamps: false,
  );
  @override
  ModelDefinition<Image> get modelDefinition => Image.definition;
  String get url => getAttr('url');
}

final class Tag extends Model {
  static final ModelDefinition<Tag> definition = ModelDefinition<Tag>(
    table: 'tags',
    factory: Tag.new,
    guarded: [],
    timestamps: false,
    relations: {
      'posts': () => MorphedByMany<Post>(
        () => Post.definition,
        morphName: 'taggable',
        foreignPivotKey: 'tag_id',
      ),
      'videos': () => MorphedByMany<Video>(
        () => Video.definition,
        morphName: 'taggable',
        foreignPivotKey: 'tag_id',
      ),
    },
  );
  @override
  ModelDefinition<Tag> get modelDefinition => Tag.definition;
  String get name => getAttr('name');
}

const List<String> _tables = [
  'users',
  'posts',
  'videos',
  'comments',
  'reactions',
  'images',
  'tags',
  'taggables',
];

Future<DatabaseManager> _database(DatabaseOpener open) async {
  final db = open();
  final schema = await freshSchema(db, _tables);
  await schema.create('users', (t) {
    t.id();
    t.string('name');
  });
  await schema.create('posts', (t) {
    t.id();
    t.integer('user_id');
    t.string('title');
    t.timestamp('deleted_at').nullable();
    t.timestamps();
  });
  await schema.create('videos', (t) {
    t.id();
    t.integer('user_id');
    t.string('title');
  });
  await schema.create('comments', (t) {
    t.id();
    t.nullableMorphs('commentable');
    t.string('body');
    t.boolean('approved').defaultTo(false);
  });
  await schema.create('reactions', (t) {
    t.id();
    t.integer('comment_id');
    t.string('emoji');
  });
  await schema.create('images', (t) {
    t.id();
    t.morphs('imageable');
    t.string('url');
  });
  await schema.create('tags', (t) {
    t.id();
    t.string('name');
  });
  await schema.create('taggables', (t) {
    t.integer('tag_id');
    t.morphs('taggable');
  });
  return db;
}

void main() => forEachDatabase(polymorphicTests);

/// Also run on MySQL and MariaDB by daravel_mysql/test/orm_matrix_test.dart.
void polymorphicTests(DatabaseOpener open) {
  late DatabaseManager db;
  late User ana;
  late User bo;
  late Post post;
  late Video video;

  MorphMany<Comment> comments(ModelDefinition<Model> parent) =>
      parent.requireRelation('comments') as MorphMany<Comment>;

  setUp(() async {
    db = await _database(open);
    Relation.morphMap({}, false);
    Relation.requireMorphMap(false);
    ana = await User.definition.query(db: db).create({'name': 'Ana'});
    bo = await User.definition.query(db: db).create({'name': 'Bo'});
    // Same id 1 on purpose: the morph type keeps their rows apart.
    post = await Post.definition.query(db: db).create({
      'user_id': ana.key,
      'title': 'Hello',
    });
    video = await Video.definition.query(db: db).create({
      'user_id': bo.key,
      'title': 'Clip',
    });
    expect(post.id, video.id);
  });

  tearDown(() async {
    Relation.morphMap({}, false);
    Relation.requireMorphMap(false);
    await db.closeAll();
  });

  group('schema', () {
    test('morphs() creates Laravel\'s columns and composite index', () async {
      if (db.dialectOf() != SqlDialect.sqlite) {
        markTestSkipped('Reads the schema with SQLite PRAGMAs.');
        return;
      }
      final columns = await db.select('PRAGMA table_info(images)');
      final byName = {for (final c in columns) c['name']: c};
      expect(byName['imageable_type']?['type'], contains('VARCHAR'));
      expect(byName['imageable_id']?['notnull'], 1);
      final nullable = await db.select('PRAGMA table_info(comments)');
      expect(
        nullable.firstWhere((c) => c['name'] == 'commentable_id')['notnull'],
        0,
      );
      final indexes = await db.select('PRAGMA index_list(images)');
      expect(
        indexes.map((i) => i['name']),
        contains('images_imageable_type_imageable_id_index'),
      );
    });
  });

  group('morphMany / morphOne', () {
    test(
      'create stores the morph class and id; eager loads never collide',
      () async {
        final c1 = await comments(Post.definition)
            .create(post, db, {'body': 'Nice post'});
        await comments(Video.definition)
            .create(video, db, {'body': 'Nice clip'});
        expect(c1.getAttr<String>('commentable_type'), r'App\Models\Post');
        expect(c1.getAttr<int>('commentable_id'), post.id);

        final posts = await Post.definition.query(db: db).with_([
          'comments',
        ]).get();
        expect(
          posts.single.related<List<Comment>>('comments').map((c) => c.body),
          ['Nice post'],
        );
        final lazy = await video.relatedQuery<Comment>('comments').get();
        expect(lazy.map((c) => c.body), ['Nice clip']);
      },
    );

    test('withCount and whereHas through a morphMany', () async {
      await comments(Post.definition).create(post, db, {'body': 'a'});
      await comments(Post.definition).create(post, db, {'body': 'b'});
      await comments(Video.definition).create(video, db, {'body': 'Great'});
      final counted = await Post.definition
          .query(db: db)
          .withCount('comments')
          .first();
      expect(counted!.getAttr<int>('comments_count'), 2);
      expect(
        await Video.definition
            .query(db: db)
            .whereHas('comments', (q) => q.where('body', 'Great'))
            .count(),
        1,
      );
      expect(
        await Post.definition
            .query(db: db)
            .whereHas('comments', (q) => q.where('body', 'Great'))
            .count(),
        0,
      );
    });

    test('morphOne loads one model or null', () async {
      await (Post.definition.requireRelation('image') as MorphOne<Image>)
          .create(post, db, {'url': '/a.png'});
      final loaded = await Post.definition.query(db: db).with_('image').first();
      expect(loaded!.related<Image?>('image')!.url, '/a.png');
      await post.delete();
      final other = await Post.definition.query(db: db).create({
        'user_id': ana.key,
        'title': 'Bare',
      });
      await other.load('image');
      expect(other.related<Image?>('image'), isNull);
    });
  });

  group('morphTo', () {
    late Comment onPost;
    late Comment onVideo;

    setUp(() async {
      onPost = await comments(Post.definition)
          .create(post, db, {'body': 'on post', 'approved': true});
      onVideo = await comments(Video.definition)
          .create(video, db, {'body': 'on video'});
    });

    test('lazy and eager loading resolve each row to its own model', () async {
      final owner = await onVideo.relatedQuery<Model>('commentable').first();
      expect(owner, isA<Video>());

      final queries = <String>[];
      db.listen((event) => queries.add(event.sql));
      final all = await Comment.definition
          .query(db: db)
          .with_(['commentable', 'commentable.author'])
          .orderBy('id')
          .get();
      final owners = [for (final c in all) c.related<Model?>('commentable')];
      expect(owners[0], isA<Post>());
      expect((owners[0]! as Post).title, 'Hello');
      expect(owners[1], isA<Video>());
      // Nested relations load per type: the post's author is Ana, the
      // video's is Bo.
      expect(owners[0]!.related<User?>('author')!.name, 'Ana');
      expect(owners[1]!.related<User?>('author')!.name, 'Bo');
      // comments + posts + videos + users (posts) + users (videos).
      expect(queries, hasLength(5));
    });

    test('associate, dissociate and touches', () async {
      final relation =
          Comment.definition.requireRelation('commentable') as MorphTo;
      final comment = Comment.definition.newInstance({'body': 'moving'}, db);
      relation.associate(comment, video);
      expect(comment.getAttr<String>('commentable_type'), r'App\Models\Video');
      expect(comment.getAttr<int>('commentable_id'), video.id);
      expect(comment.related<Model?>('commentable'), same(video));
      relation.dissociate(comment);
      expect(comment.getAttr<Object?>('commentable_type'), isNull);

      await db.table('posts').update({'updated_at': '2000-01-01 00:00:00'});
      onPost.setAttr('body', 'edited');
      await onPost.save();
      final touched = await Post.definition.query(db: db).first();
      expect(
        '${touched!.getAttr<Object?>('updated_at')}',
        isNot(contains('2000')),
      );
    });

    test('the morph map stores and resolves aliases', () async {
      Relation.morphMap({
        'post': () => Post.definition,
        'video': () => Video.definition,
      });
      final aliased = await comments(Post.definition)
          .create(post, db, {'body': 'aliased'});
      expect(aliased.getAttr<String>('commentable_type'), 'post');
      final owner = await aliased.relatedQuery<Model>('commentable').first();
      expect(owner, isA<Post>());
      // Rows written before the alias still use the class name, which the
      // relation's types still resolve.
      await onPost.load('commentable');
      expect(onPost.related<Model?>('commentable'), isA<Post>());
    });

    test('enforceMorphMap refuses models without an alias', () async {
      Relation.enforceMorphMap({'post': () => Post.definition});
      expect(Relation.morphClassOf(Post.definition), 'post');
      expect(
        () => Relation.morphClassOf(Video.definition),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            r'No morph map defined for model [App\Models\Video].',
          ),
        ),
      );
    });

    test('unknown stored types fail with a clear message', () async {
      await db.table('comments').insert({
        'commentable_type': r'App\Models\Podcast',
        'commentable_id': 1,
        'body': 'orphan',
      });
      expect(
        () => Comment.definition.query(db: db).with_('commentable').get(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains(r'[App\Models\Podcast]'),
          ),
        ),
      );
    });

    test('whereHas, whereHasMorph and whereDoesntHave on a morphTo', () async {
      ModelQuery<Comment> query() =>
          Comment.definition.query(db: db).orderBy('id');
      List<String> bodies(List<Comment> list) => [for (final c in list) c.body];

      expect(bodies(await query().has('commentable').get()), [
        'on post',
        'on video',
      ]);
      expect(
        bodies(
          await query().whereHasMorph(
            'commentable',
            [Post.definition, Video.definition],
            (q, type) =>
                q.where('title', type == Post.definition ? 'Hello' : 'nothing'),
          ).get(),
        ),
        ['on post'],
      );
      expect(
        bodies(
          await query().whereHasMorph('commentable', [Video.definition]).get(),
        ),
        ['on video'],
      );

      // A soft-deleted post no longer counts as an owner.
      await post.delete();
      await db.table('comments').insert({'body': 'no owner'});
      expect(bodies(await query().whereDoesntHave('commentable').get()), [
        'on post',
        'no owner',
      ]);
      expect(
        bodies(
          await query().whereDoesntHaveMorph('commentable', [
            Post.definition,
          ]).get(),
        ),
        ['on post'],
      );
      expect(await query().whereHasMorph('commentable', []).count(), 0);
    });
  });

  group('nested whereHas', () {
    setUp(() async {
      final c = await comments(Post.definition)
          .create(post, db, {'body': 'approved', 'approved': true});
      await db.table('reactions').insert({
        'comment_id': c.key,
        'emoji': 'fire',
      });
      final bosPost = await Post.definition.query(db: db).create({
        'user_id': bo.key,
        'title': 'Quiet',
      });
      await comments(Post.definition).create(bosPost, db, {'body': 'pending'});
    });

    ModelQuery<User> users() => User.definition.query(db: db).orderBy('id');
    List<String> names(List<User> list) => [for (final u in list) u.name];

    test('two and three levels build nested EXISTS', () async {
      final twoLevels = users().whereHas(
        'posts.comments',
        (q) => q.where('approved', true),
      );
      expect(
        RegExp('EXISTS').allMatches(twoLevels.toSql()).length,
        2,
        reason: twoLevels.toSql(),
      );
      expect(names(await twoLevels.get()), ['Ana']);
      expect(
        names(
          await users()
              .whereHas(
                'posts.comments.reactions',
                (q) => q.where('emoji', 'fire'),
              )
              .get(),
        ),
        ['Ana'],
      );
      expect(names(await users().has('posts.comments').get()), ['Ana', 'Bo']);
    });

    test('doesntHave, orWhereHas and withWhereHas', () async {
      expect(
        names(
          await users()
              .whereDoesntHave(
                'posts.comments',
                (q) => q.where('approved', true),
              )
              .get(),
        ),
        ['Bo'],
      );
      expect(
        names(
          await users()
              .where('name', 'nobody')
              .orWhereHas('posts.comments', (q) => q.where('body', 'pending'))
              .get(),
        ),
        ['Bo'],
      );
      final loaded = await users()
          .withWhereHas('posts.comments', (q) => q.where('approved', true))
          .get();
      expect(names(loaded), ['Ana']);
      final post = loaded.single.related<List<Post>>('posts').single;
      expect(post.related<List<Comment>>('comments').map((c) => c.body), [
        'approved',
      ]);
    });

    test('nesting continues through a morphTo', () async {
      // Bo wrote "Quiet" (a post); no video is commented in this group.
      expect(
        await Comment.definition
            .query(db: db)
            .whereHas('commentable.author', (q) => q.where('name', 'Bo'))
            .pluck('body'),
        ['pending'],
      );
    });
  });

  group('morphToMany / morphedByMany', () {
    late Tag dart;
    late Tag php;

    setUp(() async {
      dart = await Tag.definition.query(db: db).create({'name': 'dart'});
      php = await Tag.definition.query(db: db).create({'name': 'php'});
      await post.attach('tags', [dart, php]);
      await video.attach('tags', [php]);
    });

    test('pivot rows carry the morph type; same ids never collide', () async {
      final rows = await db.select(
        'SELECT tag_id, taggable_type FROM taggables ORDER BY taggable_type, tag_id',
      );
      expect(rows, [
        {'tag_id': dart.key, 'taggable_type': r'App\Models\Post'},
        {'tag_id': php.key, 'taggable_type': r'App\Models\Post'},
        {'tag_id': php.key, 'taggable_type': r'App\Models\Video'},
      ]);
      await video.load('tags');
      expect(video.related<List<Tag>>('tags').map((t) => t.name), ['php']);
      expect((await post.relatedQuery<Tag>('tags').get()).map((t) => t.name), [
        'dart',
        'php',
      ]);
    });

    test('sync and detach only touch the parent\'s own type', () async {
      await post.sync('tags', [dart]);
      await video.load('tags');
      expect(video.related<List<Tag>>('tags').map((t) => t.name), ['php']);
      expect(await video.detach('tags'), 1);
      await post.load('tags');
      expect(post.related<List<Tag>>('tags').map((t) => t.name), ['dart']);
    });

    test('the inverse side loads and filters by type', () async {
      final tags = await Tag.definition
          .query(db: db)
          .with_(['posts', 'videos'])
          .orderBy('id')
          .get();
      expect(tags[0].related<List<Post>>('posts'), hasLength(1));
      expect(tags[0].related<List<Video>>('videos'), isEmpty);
      expect(tags[1].related<List<Video>>('videos'), hasLength(1));
      expect(
        await Tag.definition.query(db: db).whereHas('videos').pluck('name'),
        ['php'],
      );
      final counted = await Tag.definition
          .query(db: db)
          .withCount('posts')
          .orderBy('id')
          .get();
      expect([for (final t in counted) t.getAttr<int>('posts_count')], [1, 1]);
    });
  });
}
