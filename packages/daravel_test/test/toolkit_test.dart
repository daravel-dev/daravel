import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

final class Member extends Model with AuthenticatableModel {
  static final ModelDefinition<Member> definition = ModelDefinition<Member>(
    table: 'members',
    factory: Member.new,
    fillable: ['name', 'email', 'password'],
    softDeletes: true,
    casts: {'created_at': Cast.dateTime, 'updated_at': Cast.dateTime},
  );

  @override
  ModelDefinition<Member> get modelDefinition => Member.definition;

  static ModelQuery<Member> query() => definition.query();

  int get id => getAttr('id');
  String get name => getAttr('name');
  DateTime? get createdAt => getAttr('created_at');
}

final class CreateMembers extends Migration {
  const CreateMembers();
  @override
  String get name => '2026_01_01_000000_create_members';
  @override
  Future<void> up(SchemaBuilder schema) => schema.create('members', (t) {
    t.id();
    t.string('name');
    t.string('email').unique();
    t.string('password').nullable();
    t.timestamps();
    t.softDeletes();
  });
  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('members');
}

final class Welcome extends Job {
  const Welcome(this.memberId);
  final Object memberId;
  static int handled = 0;
  @override
  String get jobName => 'welcome';
  @override
  Map<String, Object?> toJson() => {'id': memberId};
  @override
  Future<void> handle(JobContext ctx) async => handled++;
}

Application
build() => Application.configure(basePath: Directory.systemTemp.path)
    .withEnv({
      'APP_ENV': 'testing',
      'DB_DATABASE': ':memory:',
      'QUEUE_CONNECTION': 'sync',
      'APP_KEY': 'base64:${'A' * 43}=',
    })
    .withLogLevel(LogLevel.warning)
    .withMigrations(const [CreateMembers(), CreatePersonalAccessTokensTable()])
    .withJobs([JobDefinition('welcome', (j) => Welcome(j['id']!))])
    .withAuth(
      (auth) => auth.token<Member>(
        'token',
        ModelUserProvider<Member>(Member.definition),
      ),
    )
    .withRouting(
      apiPrefix: '',
      api: (router) {
        router.post('/members', (req) async {
          final data = await req.validate({
            'name': 'required|min:2',
            'email': 'required|email',
          });
          final member = await DB.transaction(() async {
            final m = await Member.query().create(data.toMap());
            await Queue.dispatch(Welcome(m.id));
            return m;
          });
          return Response.created({
            'data': {
              'id': member.id,
              'name': member.name,
              'tags': ['a', 'b'],
            },
          });
        });
        router
            .get('/me', (req) async => {'id': (await req.user<Member>())!.id})
            .middleware(const ['auth']);
        router.get('/boom', (_) => throw StateError('kaboom'));
        router.get(
          '/go',
          (_) =>
              Response(status: 302, headers: Headers({'location': '/there'})),
        );
      },
    )
    .create();

void main() {
  final db = refreshDatabase(build);

  db.test('first test writes rows inside a rolled-back transaction', () async {
    (await db.client.post(
          '/members',
          json: {'name': 'Ana', 'email': 'ana@x.io'},
        ))
        .assertCreated()
        .assertJsonStructure({
          'data': ['id', 'name', 'tags'],
        })
        .assertJsonFragment({'name': 'Ana'})
        .assertJsonMissing({'name': 'Bo'})
        .assertJsonMissingPath('data.password')
        .assertValid();
    await assertDatabaseHas('members', {'email': 'ana@x.io'});
    await assertDatabaseCount('members', 1);
    // The job was dispatched after the app-level transaction "committed",
    // even though the test transaction itself never commits.
    expect(Welcome.handled, 1);
  });

  db.test('second test starts from a clean database', () async {
    await assertDatabaseEmpty('members');
    await assertDatabaseMissing('members', {'email': 'ana@x.io'});
  });

  db.test('validation assertions', () async {
    (await db.client.post('/members', json: {'name': 'A'}))
        .assertInvalid(['name', 'email'])
        .assertJsonValidationErrors({'email': 'The email field is required.'})
        .assertJsonMissingValidationErrors(['tags']);
  });

  db.test('soft delete and model assertions', () async {
    final member = await Member.query().create({
      'name': 'Cy',
      'email': 'cy@x.io',
    });
    await assertModelExists(member);
    await assertNotSoftDeleted(member);
    await member.delete();
    await assertSoftDeleted(member);
    await assertSoftDeleted('members', {'email': 'cy@x.io'});
    await member.forceDelete();
    await assertModelMissing(member);
  });

  db.test('actingAs authenticates without tokens', () async {
    final member = await Member.query().create({
      'name': 'Di',
      'email': 'di@x.io',
    });
    (await db.client.get('/me')).assertUnauthorized();
    (await db.client.actingAs(member).get('/me'))
        .assertOk()
        .assertJsonPath('id', member.id);
    (await db.client.actingAs(member, guard: 'token').get('/me')).assertOk();
  });

  db.test('withoutExceptionHandling surfaces the real error', () async {
    (await db.client.get('/boom')).assertServerError();
    await expectLater(
      db.client.withoutExceptionHandling().get('/boom'),
      throwsA(isA<StateError>().having((e) => e.message, 'message', 'kaboom')),
    );
    (await db.client.json(
      'get',
      '/go',
    )).assertRedirect('/there').assertDontSee('kaboom');
  });

  db.test('fakes are restored between tests (part 1: fake)', () async {
    final queue = Queue.fake();
    final events = Event.fake();
    await Queue.dispatch(const Welcome(1));
    queue.assertPushed<Welcome>();
    events.assertNothingDispatched();
  });

  db.test('fakes are restored between tests (part 2: real again)', () async {
    final before = Welcome.handled;
    await Queue.dispatch(const Welcome(2));
    expect(Welcome.handled, before + 1);
  });

  db.test('time travel drives timestamps and token expiry', () async {
    final frozen = travelTo(DateTime.utc(2030, 1, 1, 12));
    final member = await Member.query().create({
      'name': 'Ed',
      'email': 'ed@x.io',
    });
    expect(member.createdAt, frozen);
    final token = await Auth.issueToken(
      member,
      'cli',
      expiresAt: frozen.add(const Duration(hours: 1)),
    );
    final client = db.client.withToken(token.plainTextToken);
    (await client.get('/me')).assertOk();
    travel(const Duration(hours: 2));
    (await client.get('/me')).assertUnauthorized();
    expect(freezeTime(), Clock.now());
  });

  test('Clock is real again outside travelling tests', () {
    expect(Clock.isFaked, isFalse);
    expect(DateTime.now().difference(Clock.now()).inSeconds.abs(), lessThan(5));
  });

  group('architecture helpers', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('daravel_arch_');
      Directory('${root.path}/lib/app/http').createSync(recursive: true);
      Directory('${root.path}/lib/app/jobs').createSync(recursive: true);
      Directory('${root.path}/bootstrap').createSync(recursive: true);
    });

    tearDown(() => root.delete(recursive: true));

    test('pass on a clean project and fail on violations', () {
      File('${root.path}/lib/app/http/ok.dart')
          .writeAsStringSync('class Ok { static const x = 1; }\n');
      expectNoMutableStatics(root.path);
      expectRegistryComplete(root.path);
      expectLintClean(root.path);
      expectNoImports('lib/app/http', [RegExp('^dart:io')], root: root.path);

      File('${root.path}/lib/app/http/bad.dart').writeAsStringSync(
        "import 'dart:io';\nclass Bad { static int n = 0; }\n",
      );
      File('${root.path}/lib/app/jobs/lost.dart')
          .writeAsStringSync('class Lost {}\n');
      expect(
        () => expectNoMutableStatics(root.path),
        throwsA(isA<TestFailure>()),
      );
      expect(
        () => expectRegistryComplete(root.path),
        throwsA(isA<TestFailure>()),
      );
      expect(() => expectLintClean(root.path), throwsA(isA<TestFailure>()));
      expect(
        () => expectNoImports('lib/app/http', [
          RegExp('^dart:io'),
        ], root: root.path),
        throwsA(isA<TestFailure>()),
      );
    });
  });
}
