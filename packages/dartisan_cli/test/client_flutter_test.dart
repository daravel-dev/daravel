import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The server rules of `POST /api/signup`; [taken] is the server-only part.
final Rule taken = ClosureRule(
  (c) => c.value == 'taken@daravel.dev' ? 'The email is taken.' : null,
  name: 'available',
);

Map<String, Object> signupRules({bool serverOnly = true}) => {
  'name': 'required|string|min:2|max:20',
  'email': ['required', 'email', if (serverOnly) taken],
  'age': 'nullable|integer|between:18,99',
  'role': 'required|in:admin,editor',
  'code': 'sometimes|digits:4',
  'slug': 'required|alpha_dash|lowercase|starts_with:a,b',
  'website': 'nullable|url',
  'password': [
    Rules.required(),
    Rules.password(min: 8, mixedCase: true, numbers: true),
    Rules.confirmed(),
  ],
  'tags.*': 'string',
};

const Map<String, String> signupAttributes = {'email': 'email address'};
const Map<String, String> signupMessages = {'name.min': 'Name is too short.'};

final class SignupRequest extends FormRequest {
  const SignupRequest();
  @override
  Map<String, Object> rules(Request request) => signupRules();
  @override
  Map<String, String> attributes() => signupAttributes;
  @override
  Map<String, String> messages() => signupMessages;
}

const Map<String, Object?> accountSchema = {
  'type': 'object',
  'required': ['id', 'name', 'role'],
  'properties': {
    'id': {'type': 'integer'},
    'name': {'type': 'string'},
    'role': {'type': 'string'},
    'score': {'type': 'number'},
    'created_at': {
      'type': ['string', 'null'],
      'format': 'date-time',
    },
    'address': {
      'type': 'object',
      'properties': {
        'city': {'type': 'string'},
      },
    },
    'labels': {
      'type': 'array',
      'items': {'type': 'string'},
    },
  },
};

Map<String, Object?> account(int id) => {
  'id': id,
  'name': 'Account $id',
  'role': 'admin',
  'score': 1.5,
  'created_at': '2026-10-26T08:00:00.000Z',
  'address': {'city': 'Singaraja'},
  'labels': ['a', 'b'],
};

void routes(Router r) {
  r
      .post('/signup', (request) async {
        final data = request.validated().toMap();
        return Response.json({
          'data': {...account(1), 'name': data['name']},
        }, status: 201);
      })
      .name('accounts.signup')
      .validates(const SignupRequest())
      .returns(accountSchema, name: 'Account');
  r
      .get('/accounts', (request) async {
        final page = int.parse(request.query['page'] ?? '1');
        return Response.json({
          'data': [account(page * 10), account(page * 10 + 1)],
          'links': {
            'first': '/api/accounts?page=1',
            'last': '/api/accounts?page=3',
            'prev': null,
            'next': '/api/accounts?page=${page + 1}',
          },
          'meta': {
            'current_page': page,
            'from': 1,
            'last_page': 3,
            'path': '/api/accounts',
            'per_page': 2,
            'to': 2,
            'total': 6,
            'search': request.query['search'],
          },
        });
      })
      .name('accounts.index')
      .rules({'search': 'nullable|string|max:10'})
      .returns(accountSchema, name: 'Account', shape: .paginated);
  r
      .get(
        '/accounts/{id}',
        (request) async =>
            Response.json({'data': account(request.param<int>('id'))}),
      )
      .name('accounts.show')
      .whereNumber('id')
      .returns(accountSchema, name: 'Account');
  r
      .post('/avatar', (request) async {
        final file = await request.file('avatar');
        return Response.json({
          'size': file?.size,
          'caption': await request.input<String>('caption'),
        });
      })
      .name('accounts.avatar')
      .rules({'avatar': 'required|file|max:100', 'caption': 'nullable|string'});
  r
      .get(
        '/tags',
        (_) async => Response.json({
          'data': [
            {'name': 'dart'},
            {'name': 'laravel'},
          ],
        }),
      )
      .name('tags')
      .returns({
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
        },
      }, shape: .collection);
  r.get(
    '/events',
    (_) => Response.sse(
      Stream<Object?>.fromIterable([
        {'n': 1},
        const SseEvent('two', event: 'status', id: '2'),
      ]),
      heartbeat: null,
    ),
  );
  r.ws('/rooms/{room}', (socket, request) {
    socket.add('joined ${request.param<String>('room')}');
  });
  r
      .get('/class', (_) async => Response.json({'ok': true}))
      .name('class.default');
  r
      .delete('/accounts/{id}', (_) async => Response.noContent())
      .name('accounts.destroy')
      .whereNumber('id')
      .returns(const <String, Object?>{}, status: 204);
  // A titled schema inside another response is the same model class.
  r
      .get(
        '/session',
        (_) async => Response.json({'account': account(5), 'token': 't'}),
      )
      .name('session')
      .returns(const {
        'title': 'Session',
        'type': 'object',
        'required': ['account', 'token'],
        'properties': {
          'account': {...accountSchema, 'title': 'Account'},
          'token': {'type': 'string'},
        },
      }, shape: .raw);
}

Application buildApp() =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'APP_NAME': 'Client Test',
        })
        .withRouting(
          web: (r) => r.get('/home', (_) => Response.text('hi')),
          api: routes,
        )
        .create();

void main() {
  late Application app;
  late GeneratedClient client;

  setUpAll(() async {
    app = buildApp();
    await app.boot();
    client = generateClient(
      routesUnder(app.router.routes, '/api'),
      packageName: 'app_client',
      baseUrl: 'http://127.0.0.1:8000',
      title: 'Client Test',
      states: clientStates.toSet(),
    );
  });

  tearDownAll(() => app.shutdown());

  String file(String path) => client.files[path]!;

  test('only API routes, grouped by route name', () {
    final api = file('lib/src/api.dart');
    expect(api, isNot(contains('/home')));
    expect(api, contains('final class AppClient extends DaravelClient'));
    expect(api, contains('late final AccountsApi accounts'));
    // `class.default`: reserved words get a suffix.
    expect(api, contains('late final ClassValueApi classValue'));
    expect(api, contains('defaultValue('));
    // A one-segment name is a method on the client itself.
    expect(api, contains('Future<List<TagsItem>> tags('));
    expect(client.operations, 10);
  });

  test('typed signatures from rules, path constraints and responses', () {
    final api = file('lib/src/api.dart');
    expect(
      api,
      contains(
        'Future<Account> signup({required String name, required String email, '
        'int? age, required String role, String? code, required String slug, '
        'String? website, required String password, '
        'required String passwordConfirmation, List<String>? tags})',
      ),
    );
    expect(
      api,
      contains('Future<Page<Account>> index({String? search, int? page})'),
    );
    expect(api, contains('Future<Account> show(int id, '));
    expect(
      api,
      contains("'/api/accounts/\${Uri.encodeComponent(id.toString())}'"),
    );
    // Files go as multipart parts.
    expect(
      api,
      contains('avatar({required http.MultipartFile avatar, String? caption})'),
    );
    expect(api, contains('files: input.files'));
  });

  test('WebSocket routes become URLs, SSE routes plain calls', () {
    final api = file('lib/src/api.dart');
    expect(
      api,
      contains(
        'Uri socketRoomsByRoom(String room) => '
        "webSocketUri('/api/rooms/\${Uri.encodeComponent(room.toString())}');",
      ),
    );
    expect(api, contains('getEvents('));
  });

  test('models decode dates, nested objects and lists', () {
    final models = file('lib/src/models.dart');
    expect(models, contains('final class Account {'));
    expect(models, contains('final DateTime? createdAt;'));
    expect(
      models,
      contains("map['created_at'] == null ? null : DateTime.parse("),
    );
    expect(models, contains('final AccountAddress? address;'));
    expect(models, contains('final List<String>? labels;'));
    expect(models, contains("'created_at': createdAt?.toIso8601String()"));
    expect(models, contains('final class TagsItem {'));
    // `title`: one Account class, reused inside Session.
    expect('final class Account {'.allMatches(models), hasLength(1));
    expect(models, contains('final Account account;'));
    expect(models, isNot(contains('SessionAccount')));
  });

  test('204 responses are Future<void>', () {
    final api = file('lib/src/api.dart');
    expect(api, contains('Future<void> destroy(int id, '));
    expect(api, contains("await _client.send('DELETE', "));
  });

  test('validators carry the server messages and name server-only rules', () {
    final inputs = file('lib/src/inputs.dart');
    expect(inputs, contains('final class AccountsSignupInput {'));
    // The FormRequest's attribute name and custom message.
    expect(inputs, contains("'The email address field is required.'"));
    expect(inputs, contains("'Name is too short.'"));
    expect(inputs, contains('static String? validateEmail(Object? value'));
    expect(
      inputs,
      contains('Checked by the server only: `email`: available; `tags.*`.'),
    );
    expect(client.notes, contains(contains('server-only rules')));
  });

  test('state adapters: providers, cubits, blocs and their dependencies', () {
    expect(
      file('pubspec.yaml'),
      allOf(contains('bloc: ^9.0.0'), contains('riverpod: ^3.0.0')),
    );
    expect(
      file('lib/app_client.dart'),
      allOf(
        contains("export 'src/providers.dart';"),
        contains("export 'src/cubits.dart';"),
        contains("export 'src/blocs.dart';"),
        contains("export 'src/remote_state.dart';"),
      ),
    );
    final providers = file('lib/src/providers.dart');
    expect(
      providers,
      contains('final appClientProvider = Provider<AppClient>'),
    );
    // GETs only; several parameters make a record argument.
    expect(
      providers,
      contains(
        'final accountsIndexProvider = FutureProvider.autoDispose\n'
        '    .family<Page<Account>, ({String? search, int? page})>(',
      ),
    );
    expect(providers, contains('.family<Account, int>('));
    expect(providers, isNot(contains('signupProvider')));
    final cubits = file('lib/src/cubits.dart');
    expect(
      cubits,
      contains(
        'final class AccountsSignupCubit extends Cubit<RemoteState<Account>>',
      ),
    );
    expect(cubits, contains('Future<void> submit({'));
    expect(cubits, contains('Future<void> load(int id) =>'));
    // A 204 is a RemoteState<void>.
    expect(cubits, contains('Cubit<RemoteState<void>>'));
    final blocs = file('lib/src/blocs.dart');
    expect(blocs, contains('final class AccountsShowRequested {'));
    expect(
      blocs,
      contains(
        'final class AccountsShowBloc extends '
        'Bloc<AccountsShowRequested, RemoteState<Account>> {',
      ),
    );
  });

  test('no adapters: no adapter files or dependencies', () {
    final plain = generateClient(
      routesUnder(app.router.routes, '/api'),
      packageName: 'app_client',
      baseUrl: 'x',
    );
    expect(plain.files.keys, isNot(contains('lib/src/providers.dart')));
    expect(plain.files['pubspec.yaml'], isNot(contains('riverpod')));
  });

  test('watch regenerates on a saved source, not on other files', () async {
    final root = await Directory.systemTemp.createTemp('client_watch_');
    addTearDown(() => root.delete(recursive: true));
    for (final dir in ['routes', 'lib', 'out']) {
      Directory(p.join(root.path, dir)).createSync();
    }
    final runs = StreamController<void>.broadcast();
    addTearDown(runs.close);
    var count = 0;
    final watcher = ClientWatcher(
      root: root.path,
      exclude: p.join(root.path, 'out'),
      debounce: const Duration(milliseconds: 50),
      out: StringBuffer(),
      regenerate: () async {
        count++;
        runs.add(null);
        return 0;
      },
    );
    await watcher.start();
    addTearDown(watcher.stop);
    final next = runs.stream.first.timeout(const Duration(seconds: 10));
    File(p.join(root.path, 'routes', 'api.dart')).writeAsStringSync('// x');
    await next;
    expect(count, 1);
    // macOS (FSEvents) can deliver one save in two batches about a second
    // apart, which is a second run; let them settle before the baseline.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final settled = count;
    // Not Dart, or inside the generated package: ignored.
    File(p.join(root.path, 'lib', 'notes.txt')).writeAsStringSync('x');
    Directory(p.join(root.path, 'lib', 'out')).createSync();
    File(p.join(root.path, 'out', 'api.dart')).writeAsStringSync('// y');
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(count, settled);
  });

  group(
    'generated package (pub get, analyze, run against a server)',
    () {
      late ServerEngine engine;
      late Directory dir;

      setUpAll(() async {
        engine = ServerEngine(
          app,
          const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
          kernel: app.kernel,
          logger: Logger(minimumLevel: LogLevel.critical),
        );
        await engine.start();
        dir = await Directory.systemTemp.createTemp('client_flutter_');
        await writeClient(client, dir.path);
        await File(p.join(dir.path, 'bin', 'parity.dart'))
            .create(recursive: true);
        await File(p.join(dir.path, 'bin', 'parity.dart'))
            .writeAsString(_program);
      });

      tearDownAll(() async {
        await engine.stop();
        try {
          await dir.delete(recursive: true);
        } on FileSystemException {
          // Windows may still hold a file; the temp folder is cleaned later.
        }
      });

      Future<ProcessResult> dart(List<String> args) => Process.run(
        Platform.resolvedExecutable,
        args,
        workingDirectory: dir.path,
      );

      test('a client without paginators or uploads analyzes clean', () async {
        // Like a new project's auth routes: the adapters use no runtime type.
        final small = Application.configure(basePath: Directory.systemTemp.path)
            .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
            .withRouting(
              api: (r) {
                r
                    .post('/login', (_) async => Response.json(const {}))
                    .name('auth.login')
                    .rules({'email': 'required|email'})
                    .returns(accountSchema, name: 'Account', shape: .raw);
                r
                    .get('/me', (_) async => Response.json(const {}))
                    .name('auth.me')
                    .returns(accountSchema, name: 'Account');
              },
            )
            .create();
        await small.boot();
        addTearDown(small.shutdown);
        final out = await Directory.systemTemp.createTemp('client_small_');
        addTearDown(() async {
          try {
            await out.delete(recursive: true);
          } on FileSystemException {
            // Windows may still hold a file.
          }
        });
        await writeClient(
          generateClient(
            routesUnder(small.router.routes, '/api'),
            packageName: 'app_client',
            baseUrl: 'http://127.0.0.1:8000',
            states: clientStates.toSet(),
          ),
          out.path,
        );
        Future<ProcessResult> run(List<String> args) => Process.run(
          Platform.resolvedExecutable,
          args,
          workingDirectory: out.path,
        );
        final get = await run(['pub', 'get']);
        expect(get.exitCode, 0, reason: '${get.stdout}${get.stderr}');
        final analyze = await run(['analyze', '--fatal-infos']);
        expect(analyze.exitCode, 0, reason: '${analyze.stdout}');
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('analyzes clean and matches the server', () async {
        final get = await dart(['pub', 'get']);
        expect(get.exitCode, 0, reason: '${get.stdout}${get.stderr}');
        final analyze = await dart(['analyze', '--fatal-infos']);
        expect(analyze.exitCode, 0, reason: '${analyze.stdout}');

        final cases = _cases();
        final casesFile = File(p.join(dir.path, 'cases.json'));
        await casesFile.writeAsString(jsonEncode(cases));
        final run = await dart([
          'run',
          'bin/parity.dart',
          casesFile.path,
          'http://127.0.0.1:${engine.port}',
        ]);
        expect(run.exitCode, 0, reason: '${run.stdout}${run.stderr}');
        final out = jsonDecode(
          const LineSplitter().convert('${run.stdout}').last,
        ) as Map<String, Object?>;

        // Client-side validation == the server's Validator, message for
        // message (the server-only rule left out on both sides).
        final client = (out['validate']! as List<Object?>);
        for (var i = 0; i < cases.length; i++) {
          final server = await Validator(
            cases[i],
            signupRules(serverOnly: false),
            attributes: signupAttributes,
            messages: signupMessages,
          ).run();
          expect(client[i], server, reason: 'case $i: ${jsonEncode(cases[i])}');
        }
        // Not vacuous: the invalid case fails on every checkable field.
        expect(
          (client[2]! as Map).keys,
          unorderedEquals([
            'name',
            'email',
            'age',
            'role',
            'code',
            'slug',
            'website',
            'password',
          ]),
        );
        expect(((client[2]! as Map)['slug'] as List).length, 3);
        printOnFailure(const JsonEncoder.withIndent('  ').convert(client[2]));
        expect(out['field'], 'Name is too short.');
        expect(out['confirmed'], [
          'The password field confirmation does not match.',
        ]);

        // Against the running server.
        expect(out['created'], containsPair('name', 'Teo'));
        expect(out['createdAt'], '2026-10-26T08:00:00.000Z');
        expect((out['errors422']! as Map)['email'], ['The email is taken.']);
        expect(out['page'], [2, 3, 6, true, 20, 'Singaraja']);
        expect(out['show'], 7);
        expect(out['tags'], ['dart', 'laravel']);
        expect(out['events'], [
          ['update', '{"n":1}'],
          ['status', 'two', '2'],
        ]);
        expect(out['ws'], 'joined lobby');
        expect(out['avatar'], {'size': 3, 'caption': 'hi'});
        expect(out['session'], 5);
        expect(out['cubit'], 7);
        expect(out['cubit422'], 'The email is taken.');
        expect(out['bloc'], 8);
        expect(out['riverpod'], 9);
        expect(out['riverpodPage'], 3);
        expect(out['unauthenticated'], isNull);
      }, timeout: const Timeout(Duration(minutes: 3)));
    },
    skip: Platform.environment['DARAVEL_E2E'] == '1'
        ? false
        : 'set DARAVEL_E2E=1 to run (pub get + analyze + run, ~40 s)',
  );
}

/// Inputs covering each client-checkable rule, valid and invalid.
List<Map<String, Object?>> _cases() => [
  {},
  {
    'name': 'Teo',
    'email': 'teo@daravel.dev',
    'role': 'admin',
    'slug': 'abc',
    'password': 'Secret123',
    'password_confirmation': 'Secret123',
  },
  {
    'name': 'T',
    'email': 'not-an-email',
    'age': 12,
    'role': 'owner',
    'code': '12',
    'slug': 'Zed!',
    'website': 'ftp://x',
    'password': 'short',
    'password_confirmation': 'other',
  },
  {
    'name': 'x' * 21,
    'email': '  ',
    'age': '42',
    'role': 'editor',
    'code': 'abcd',
    'slug': 'b-ok_1',
    'website': 'https://daravel.dev',
    'password': 'alllowercase1',
    'password_confirmation': 'alllowercase1',
  },
  {
    'name': 42,
    'email': 'a@b.co',
    'age': null,
    'role': 'admin',
    'slug': 'cat',
    'website': null,
    'password': 'NoDigitsHere',
    'password_confirmation': 'NoDigitsHere',
  },
  {
    'name': ['a', 'b', 'c'],
    'email': 'a@b.co',
    'age': 100.0,
    'role': 'admin',
    'code': 1234,
    'slug': 'b',
    'password': 12345678,
  },
];

/// Runs inside the generated package: the validators on the cases, then
/// every kind of operation against the server.
const String _program = r'''
import 'dart:convert';
import 'dart:io';

import 'package:app_client/app_client.dart';
import 'package:http/http.dart' as http;
import 'package:riverpod/riverpod.dart';

Future<void> main(List<String> args) async {
  final cases = (jsonDecode(File(args[0]).readAsStringSync()) as List<Object?>)
      .cast<Map<String, Object?>>();
  final out = <String, Object?>{
    'validate': [
      for (final data in cases) validateAll(AccountsSignupInput.rules, data),
    ],
    'field': AccountsSignupInput.validateName('T'),
    'confirmed': const AccountsSignupInput(
      name: 'Teo',
      email: 'teo@daravel.dev',
      role: 'admin',
      slug: 'abc',
      password: 'Secret123',
      passwordConfirmation: 'Secret124',
    ).validate()['password'],
  };

  final api = AppClient(baseUrl: args[1]);
  final created = await api.accounts.signup(
    name: 'Teo',
    email: 'teo@daravel.dev',
    role: 'admin',
    slug: 'abc',
    password: 'Secret123',
    passwordConfirmation: 'Secret123',
  );
  out['created'] = created.toJson();
  out['createdAt'] = created.createdAt?.toIso8601String();
  try {
    await api.accounts.signup(
      name: 'Teo',
      email: 'taken@daravel.dev',
      role: 'admin',
      slug: 'abc',
      password: 'Secret123',
      passwordConfirmation: 'Secret123',
    );
  } on ValidationException catch (e) {
    out['errors422'] = e.errors;
  }
  final page = await api.accounts.index(search: 'te', page: 2);
  out['page'] = [
    page.currentPage,
    page.lastPage,
    page.total,
    page.hasMorePages,
    page.items.first.id,
    page.items.first.address?.city,
  ];
  out['show'] = (await api.accounts.show(7)).id;
  out['tags'] = [for (final tag in await api.tags()) tag.name];
  out['events'] = [
    await for (final e in api.events('/api/events'))
      [e.event, e.data, if (e.id != null) e.id],
  ];
  final socket = await WebSocket.connect(
    api.socketRoomsByRoom('lobby').toString(),
    headers: await api.requestHeaders(),
  );
  out['ws'] = await socket.first;
  await socket.close();
  out['avatar'] = await api.accounts.avatar(
    avatar: http.MultipartFile.fromBytes('avatar', [1, 2, 3], filename: 'a.png'),
    caption: 'hi',
  );
  await api.accounts.destroy(3);
  out['session'] = (await api.session()).account.id;
  out['unauthenticated'] = await api.tokens.read();

  final cubit = AccountsShowCubit(api);
  await cubit.load(7);
  out['cubit'] = (cubit.state as RemoteData<Account>).data.id;
  final signup = AccountsSignupCubit(api);
  await signup.submit(
    name: 'Teo',
    email: 'taken@daravel.dev',
    role: 'admin',
    slug: 'abc',
    password: 'Secret123',
    passwordConfirmation: 'Secret123',
  );
  out['cubit422'] = (signup.state as RemoteError<Account>).validation?.first(
    'email',
  );
  final bloc = AccountsShowBloc(api)..add(const AccountsShowRequested(8));
  final loaded = await bloc.stream.firstWhere((s) => s is RemoteData<Account>);
  out['bloc'] = (loaded as RemoteData<Account>).data.id;
  final container = ProviderContainer(
    overrides: [appClientProvider.overrideWithValue(api)],
  );
  final show = container.listen(accountsShowProvider(9).future, (_, __) {});
  out['riverpod'] = (await show.read()).id;
  final index = container.listen(
    accountsIndexProvider((search: 'x', page: 3)).future,
    (_, __) {},
  );
  out['riverpodPage'] = (await index.read()).currentPage;
  container.dispose();
  await cubit.close();
  await signup.close();
  await bloc.close();
  api.close();
  print(jsonEncode(out));
}
''';
