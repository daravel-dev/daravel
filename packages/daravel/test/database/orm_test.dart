import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test models (what `dartisan make:model` will generate)
// ---------------------------------------------------------------------------

final class User extends Model {
  static final ModelDefinition<User> definition = ModelDefinition<User>(
    table: 'users',
    factory: User.new,
    fillable: ['name', 'email', 'password', 'active', 'settings'],
    hidden: ['password'],
    casts: {
      'active': Cast.boolean,
      'settings': Cast.json,
      'created_at': Cast.dateTime,
      'updated_at': Cast.dateTime,
    },
    appends: ['shout'],
    accessors: {'shout': (u) => u.name.toUpperCase()},
    mutators: {'email': (u, v) => '$v'.toLowerCase()},
    relations: {
      'posts': () =>
          HasMany<Post>(() => Post.definition, foreignKey: 'user_id'),
      'profile': () =>
          HasOne<Profile>(() => Profile.definition, foreignKey: 'user_id'),
      'roles': () => BelongsToMany<Role>(
        () => Role.definition,
        pivotTable: 'role_user',
        foreignPivotKey: 'user_id',
        relatedPivotKey: 'role_id',
        withPivot: ['granted_by'],
      ),
      'comments': () => HasManyThrough<Comment>(
        () => Comment.definition,
        through: () => Post.definition,
        firstKey: 'user_id',
        secondKey: 'post_id',
      ),
    },
    scopes: {'active': (q, _) => q.where('active', true)},
  );

  @override
  ModelDefinition<User> get modelDefinition => User.definition;

  int get id => getAttr('id');
  String get name => getAttr('name');
  set name(String v) => setAttr('name', v);
  String get email => getAttr('email');
  bool? get active => getAttr('active');
  Map<String, Object?>? get settings =>
      (getAttr<Object?>('settings') as Map<Object?, Object?>?)?.cast();
  DateTime? get createdAt => getAttr('created_at');
  ModelCollection<Post> get posts => related('posts');
}

final class PostObserver extends ModelObserver<Post> {
  const PostObserver();
  static final events = <String>[];

  @override
  bool? creating(Post model) {
    events.add('creating:${model.title}');
    return model.title != 'forbidden' ? null : false;
  }

  @override
  bool? retrieved(Post model) {
    events.add('retrieved:${model.title}');
    return null;
  }
}

final class Post extends Model {
  static final ModelDefinition<Post> definition = ModelDefinition<Post>(
    table: 'posts',
    factory: Post.new,
    guarded: [],
    softDeletes: true,
    casts: {'meta': Cast.json, 'published': Cast.boolean},
    observers: const [PostObserver()],
    relations: {
      'user': () =>
          BelongsTo<User>(() => User.definition, foreignKey: 'user_id'),
      'comments': () =>
          HasMany<Comment>(() => Comment.definition, foreignKey: 'post_id'),
    },
    scopes: {'published': (q, _) => q.where('published', true)},
    globalScopes: [(q) => q.where('hidden', false)],
    touches: ['user'],
  );

  @override
  ModelDefinition<Post> get modelDefinition => Post.definition;

  int get id => getAttr('id');
  String get title => getAttr('title');
  bool? get published => getAttr('published');
}

final class Comment extends Model {
  static final ModelDefinition<Comment> definition = ModelDefinition<Comment>(
    table: 'comments',
    factory: Comment.new,
    guarded: [],
    timestamps: false,
    relations: {
      'post': () =>
          BelongsTo<Post>(() => Post.definition, foreignKey: 'post_id'),
    },
  );

  @override
  ModelDefinition<Comment> get modelDefinition => Comment.definition;
  String get body => getAttr('body');
}

final class Role extends Model {
  static final ModelDefinition<Role> definition = ModelDefinition<Role>(
    table: 'roles',
    factory: Role.new,
    guarded: [],
    timestamps: false,
  );
  @override
  ModelDefinition<Role> get modelDefinition => Role.definition;
  String get name => getAttr('name');
}

final class Profile extends Model {
  static final ModelDefinition<Profile> definition = ModelDefinition<Profile>(
    table: 'profiles',
    factory: Profile.new,
    guarded: [],
    timestamps: false,
  );
  @override
  ModelDefinition<Profile> get modelDefinition => Profile.definition;
  String get bio => getAttr('bio');
}

final class Ticket extends Model {
  static final ModelDefinition<Ticket> definition = ModelDefinition<Ticket>(
    table: 'tickets',
    factory: Ticket.new,
    guarded: [],
    keyType: .ulid,
    timestamps: false,
  );
  @override
  ModelDefinition<Ticket> get modelDefinition => Ticket.definition;
}

Future<DatabaseManager> _database() async {
  final db = DatabaseManager(
    const DatabaseConfig(
      defaultConnection: 'sqlite',
      connections: {
        'sqlite': ConnectionConfig(driver: 'sqlite', database: ':memory:'),
      },
    ),
  );
  final schema = SchemaBuilder(await db.executor());
  await schema.create('users', (t) {
    t.id();
    t.string('name');
    t.string('email').unique();
    t.string('password').nullable();
    t.boolean('active').defaultTo(true);
    t.text('settings').nullable();
    t.integer('logins').defaultTo(0);
    t.timestamps();
  });
  await schema.create('posts', (t) {
    t.id();
    t.integer('user_id');
    t.string('title');
    t.boolean('published').defaultTo(false);
    t.boolean('hidden').defaultTo(false);
    t.text('meta').nullable();
    t.timestamp('deleted_at').nullable();
    t.timestamps();
  });
  await schema.create('comments', (t) {
    t.id();
    t.integer('post_id');
    t.string('body');
  });
  await schema.create('roles', (t) {
    t.id();
    t.string('name');
  });
  await schema.create('role_user', (t) {
    t.integer('user_id');
    t.integer('role_id');
    t.string('granted_by').nullable();
  });
  await schema.create('profiles', (t) {
    t.id();
    t.integer('user_id');
    t.string('bio');
  });
  await schema.create('tickets', (t) {
    t.string('id', length: 26);
    t.string('subject');
  });
  return db;
}

void main() {
  late DatabaseManager db;
  ModelQuery<User> users() => User.definition.query(db: db);
  ModelQuery<Post> posts() => Post.definition.query(db: db);

  setUp(() async {
    db = await _database();
    PostObserver.events.clear();
    Model.preventSilentlyDiscardingAttributes = false;
  });

  tearDown(() => db.closeAll());

  group('attributes & persistence', () {
    test(
      'create, casts, mutators, accessors, hidden, appends and timestamps',
      () async {
        final user = await users().create({
          'name': 'Ana',
          'email': 'ANA@X.TEST',
          'password': 'secret',
          'settings': {'theme': 'dark'},
        });
        expect(user.exists, isTrue);
        expect(user.wasRecentlyCreated, isTrue);
        expect(user.id, 1);
        expect(user.email, 'ana@x.test');
        expect(user.settings, {'theme': 'dark'});
        expect(user.createdAt, isA<DateTime>());
        expect(user.attributes['settings'], '{"theme":"dark"}');

        final json = user.toJson();
        expect(json.containsKey('password'), isFalse);
        expect(json['shout'], 'ANA');
        expect(json['settings'], {'theme': 'dark'});
        expect(json['created_at'], endsWith('Z'));

        final reloaded = await users().findOrFail(1);
        expect(reloaded.name, 'Ana');
        expect(reloaded.active, isTrue);
        expect(reloaded.settings?['theme'], 'dark');
        expect(
          reloaded.makeVisible(['password']).toJson()['password'],
          'secret',
        );
      },
    );

    test(
      'dirty tracking, save, update, refresh, replicate, increment',
      () async {
        final user = await users().create({'name': 'Bo', 'email': 'bo@x.test'});
        expect(user.isDirty(), isFalse);
        user.name = 'Bob';
        expect(user.isDirty('name'), isTrue);
        expect(user.getDirty(), {'name': 'Bob'});
        expect(await user.save(), isTrue);
        expect(user.wasChanged('name'), isTrue);
        expect(user.getChanges(), containsPair('name', 'Bob'));
        expect(user.isClean(), isTrue);
        expect((await users().find(user.id))!.name, 'Bob');

        await user.update({'name': 'Bobby'});
        expect((await users().find(user.id))!.name, 'Bobby');

        await db.table('users').where('id', user.id).update({
          'name': 'External',
        });
        expect(user.name, 'Bobby');
        await user.refresh();
        expect(user.name, 'External');

        await user.increment('logins', 2);
        expect(user.getAttr<int>('logins'), 2);
        expect((await users().find(user.id))!.getAttr<int>('logins'), 2);

        final copy = user.replicate();
        expect(copy.exists, isFalse);
        expect(copy.key, isNull);
        expect(copy.getAttr<String>('name'), 'External');
        expect(user.isSameAs(await users().findOrFail(user.id)), isTrue);
      },
    );

    test('mass assignment is guarded', () async {
      final user = User.definition.newInstance({
        'name': 'x',
        'email': 'x@x.test',
        'logins': 99,
      }, db);
      expect(user.hasAttribute('logins'), isFalse);
      Model.preventSilentlyDiscardingAttributes = true;
      expect(
        () => user.fill({'logins': 1}),
        throwsA(isA<MassAssignmentException>()),
      );
      user.forceFill({'logins': 1});
      expect(user.getAttr<int>('logins'), 1);
    });

    test('client generated keys (ulid)', () async {
      final ticket = await Ticket.definition.query(db: db).create({
        'subject': 'Help',
      });
      expect(ticket.key, isA<String>());
      expect((ticket.key! as String).length, 26);
      expect(
        (await Ticket.definition.query(db: db).find(ticket.key!))
            ?.getAttr<String>('subject'),
        'Help',
      );
    });

    test('finders, pagination and helpers', () async {
      for (var i = 1; i <= 5; i++) {
        await users().create({
          'name': 'U$i',
          'email': 'u$i@x.test',
          'active': i.isOdd,
        });
      }
      expect(await users().count(), 5);
      expect(await users().scope('active').count(), 3);
      expect((await users().orderByDesc('id').first())!.name, 'U5');
      expect(await users().where('name', 'U2').sole(), isA<User>());
      expect(
        () => users().findOrFail(99),
        throwsA(isA<ModelNotFoundException>()),
      );
      expect(await users().pluck('name'), ['U1', 'U2', 'U3', 'U4', 'U5']);
      final page = await users().orderBy('id').paginate(page: 2, perPage: 2);
      expect(page.items.map((u) => u.name), ['U3', 'U4']);
      expect(page.toJson()['total'], 5);
      final created = await users().firstOrCreate(
        {'email': 'u1@x.test'},
        {'name': 'ignored'},
      );
      expect(created.name, 'U1');
      final updated = await users().updateOrCreate(
        {'email': 'new@x.test'},
        {'name': 'New'},
      );
      expect(updated.wasRecentlyCreated, isTrue);
      await users().updateOrCreate({'email': 'new@x.test'}, {'name': 'Newer'});
      expect((await users().where('email', 'new@x.test').sole()).name, 'Newer');
      expect(
        await users().where('name', 'like', 'U%').update({'active': false}),
        5,
      );
      expect(await users().scope('active').count(), 1);
      final seen = <String>[];
      await users()
          .orderBy('id')
          .chunk(4, (models, _) => seen.addAll(models.map((u) => u.name)));
      expect(seen.length, 6);
    });
  });

  group('relations', () {
    late User ana;
    late User bo;

    setUp(() async {
      ana = await users().create({'name': 'Ana', 'email': 'ana@x.test'});
      bo = await users().create({'name': 'Bo', 'email': 'bo@x.test'});
      final p1 = await posts().create({
        'user_id': ana.id,
        'title': 'Hello',
        'published': true,
        'meta': {
          'tags': ['x'],
        },
      });
      final p2 = await posts().create({'user_id': ana.id, 'title': 'Draft'});
      await posts().create({
        'user_id': bo.id,
        'title': 'Bo post',
        'published': true,
      });
      await Comment.definition.query(db: db).create({
        'post_id': p1.id,
        'body': 'nice',
      });
      await Comment.definition.query(db: db).create({
        'post_id': p1.id,
        'body': 'great',
      });
      await Comment.definition.query(db: db).create({
        'post_id': p2.id,
        'body': 'meh',
      });
      await Profile.definition.query(db: db).create({
        'user_id': ana.id,
        'bio': 'Dart dev',
      });
      final admin = await Role.definition.query(db: db).create({
        'name': 'admin',
      });
      await Role.definition.query(db: db).create({'name': 'editor'});
      await ana.attach('roles', admin, pivot: {'granted_by': 'system'});
    });

    test(
      'lazy relation queries and eager loading (nested, constrained)',
      () async {
        expect(
          (await ana.relatedQuery<Post>('posts').get()).map((p) => p.title),
          ['Hello', 'Draft'],
        );
        expect(
          (await ana.relatedQuery<Post>('posts').scope('published').count()),
          1,
        );

        final loaded = await users()
            .with_(['posts.comments', 'profile', 'roles'])
            .orderBy('id')
            .get();
        final first = loaded.first;
        expect(first.relationLoaded('posts'), isTrue);
        expect(first.posts.map((p) => p.title), ['Hello', 'Draft']);
        expect(
          first.posts.first
              .related<ModelCollection<Comment>>('comments')
              .map((c) => c.body),
          ['nice', 'great'],
        );
        expect(first.related<Profile?>('profile')?.bio, 'Dart dev');
        expect(first.related<ModelCollection<Role>>('roles').single.pivot, {
          'user_id': 1,
          'role_id': 1,
          'granted_by': 'system',
        });
        expect(loaded.last.related<Profile?>('profile'), isNull);
        expect(loaded.last.related<ModelCollection<Role>>('roles'), isEmpty);
        expect(first.toJson()['posts'], isA<List<Object?>>());
        expect(
          (first.toJson()['profile']! as Map<String, Object?>)['bio'],
          'Dart dev',
        );

        final constrained = await users()
            .with_({
              'posts': (ModelQuery<Model> q) => q.where('published', true),
            })
            .orderBy('id')
            .get();
        expect(constrained.first.posts.map((p) => p.title), ['Hello']);

        final post = await posts().with_(['user']).first();
        expect(post!.related<User?>('user')!.name, 'Ana');
        expect(() => bo.related<Object?>('posts'), throwsStateError);
        await bo.load(['posts']);
        expect(bo.posts.length, 1);
      },
    );

    test('withCount, whereHas, doesntHave and hasManyThrough', () async {
      final counted = await users()
          .withCount(['posts', 'roles'])
          .orderBy('id')
          .get();
      expect(counted.first.getAttr<int>('posts_count'), 2);
      expect(counted.first.getAttr<int>('roles_count'), 1);
      expect(counted.last.getAttr<int>('posts_count'), 1);

      expect(
        (await users()
                .whereHas('posts', (q) => q.where('title', 'Draft'))
                .get())
            .map((u) => u.name),
        ['Ana'],
      );
      expect(
        (await users().whereDoesntHave('roles').get()).map((u) => u.name),
        ['Bo'],
      );
      expect((await users().has('profile').count()), 1);
      expect(
        (await ana.relatedQuery<Comment>('comments').get()).map((c) => c.body),
        ['nice', 'great', 'meh'],
      );
      final through = await users().with_(['comments']).orderBy('id').get();
      expect(
        through.first.related<ModelCollection<Comment>>('comments').length,
        3,
      );
      expect(
        through.last.related<ModelCollection<Comment>>('comments'),
        isEmpty,
      );
    });

    test('belongsToMany attach/detach/sync', () async {
      final editor = await Role.definition
          .query(db: db)
          .where('name', 'editor')
          .sole();
      final result = await ana.sync('roles', [editor]);
      expect(result['attached'], [editor.key]);
      expect(result['detached'], [1]);
      expect((await ana.relatedQuery<Role>('roles').get()).map((r) => r.name), [
        'editor',
      ]);
      await ana.attach('roles', [1]);
      expect(await ana.relatedQuery<Role>('roles').count(), 2);
      expect(await ana.detach('roles', 1), 1);
      expect(await ana.detach('roles'), 1);
    });

    test('touches parent updated_at on save', () async {
      final before = (await users().findOrFail(ana.id))
          .getAttr<DateTime?>('updated_at');
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await posts().create({'user_id': ana.id, 'title': 'Touch'});
      final after = (await users().findOrFail(ana.id))
          .getAttr<DateTime?>('updated_at');
      expect(after, isNot(before));
    });
  });

  group('soft deletes, scopes and observers', () {
    test('soft delete lifecycle', () async {
      final user = await users().create({'name': 'A', 'email': 'a@x.test'});
      final post = await posts().create({'user_id': user.id, 'title': 'Soft'});
      await posts().create({'user_id': user.id, 'title': 'Keep'});
      expect(await post.delete(), isTrue);
      expect(post.trashed, isTrue);
      expect(await posts().count(), 1);
      expect(await posts().withTrashed().count(), 2);
      expect((await posts().onlyTrashed().sole()).title, 'Soft');
      expect(await post.restore(), isTrue);
      expect(await posts().count(), 2);
      expect(await posts().where('title', 'Keep').delete(), 1);
      expect(await posts().onlyTrashed().restore(), 1);
      await post.forceDelete();
      expect(await posts().withTrashed().count(), 1);
      expect(post.exists, isFalse);
    });

    test('global scopes apply unless disabled', () async {
      final user = await users().create({'name': 'A', 'email': 'a@x.test'});
      await posts().create({'user_id': user.id, 'title': 'Visible'});
      await db.table('posts').insert({
        'user_id': user.id,
        'title': 'Hidden',
        'hidden': true,
      });
      expect(await posts().count(), 1);
      expect(await posts().withoutGlobalScopes().count(), 2);
      expect(posts().toSql(), contains('"hidden" = ?'));
    });

    test('observers can cancel creating and see retrieved', () async {
      final user = await users().create({'name': 'A', 'email': 'a@x.test'});
      final blocked = Post.definition.newInstance({
        'user_id': user.id,
        'title': 'forbidden',
      }, db);
      expect(await blocked.save(), isFalse);
      expect(blocked.exists, isFalse);
      await posts().create({'user_id': user.id, 'title': 'ok'});
      await posts().get();
      expect(PostObserver.events, [
        'creating:forbidden',
        'creating:ok',
        'retrieved:ok',
      ]);
      final quiet = Post.definition.newInstance({
        'user_id': user.id,
        'title': 'forbidden',
      }, db);
      expect(await quiet.saveQuietly(), isTrue);
    });
  });
}
