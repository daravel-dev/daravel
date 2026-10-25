import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:dartisan_cli/src/guide_pages.g.dart';
import 'package:test/test.dart';

void main() {
  late Application app;
  final ran = <List<String>>[];

  Future<Application> boot({String env = 'local'}) async {
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': env,
          'APP_KEY': 'base64:${base64Encode(List.filled(32, 7))}',
          'DB_DATABASE': ':memory:',
        })
        .withRouting(
          api: (router) {
            router
              ..post('/posts', (_) => null)
                  .rules({
                    'title': 'required|string|max:120',
                    'email': Rules.required().email(),
                  })
                  .returns(const {'type': 'object'}, name: 'Post')
                  .action('PostController@store')
                  .name('posts.store')
              ..get('/posts/{post}', (_) => null);
          },
        )
        .create();
    await app.boot();
    await app.run(
      () => DB.statement('CREATE TABLE "posts" ("id" INTEGER, "title" TEXT)'),
    );
    return app;
  }

  McpServer server({bool allowWrite = false}) => McpServer(
    app,
    allowWrite: allowWrite,
    runCommand: (command, arguments) async {
      ran.add([command, ...arguments]);
      return (exitCode: 0, stdout: 'ok', stderr: '');
    },
  );

  Future<Map<String, Object?>> call(
    McpServer server,
    String method, [
    Map<String, Object?> params = const {},
  ]) async => (await server.handle({
    'jsonrpc': '2.0',
    'id': 1,
    'method': method,
    'params': params,
  }))!;

  Future<Object?> tool(
    McpServer server,
    String name, [
    Map<String, Object?> arguments = const {},
  ]) async {
    final response = await call(server, 'tools/call', {
      'name': name,
      'arguments': arguments,
    });
    final result = response['result']! as Map<String, Object?>;
    final text =
        ((result['content']! as List<Object?>).single!
                as Map<String, Object?>)['text']!
            as String;
    if (result['isError'] == true) {
      throw StateError(text);
    }
    try {
      return jsonDecode(text);
    } on FormatException {
      return text;
    }
  }

  setUp(() async {
    ran.clear();
    app = await boot();
  });
  tearDown(() => app.shutdown());

  test(
    'initialize negotiates the protocol; notifications get no answer',
    () async {
      final s = server();
      final init = await call(s, 'initialize', {
        'protocolVersion': '2025-06-18',
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': 'test', 'version': '1'},
      });
      final result = init['result']! as Map<String, Object?>;
      expect(result['protocolVersion'], '2025-06-18');
      expect(result['serverInfo'], {
        'name': 'dartisan',
        'version': daravelVersion,
      });
      expect(
        (await call(s, 'initialize', {
          'protocolVersion': '1999-01-01',
        }))['result'],
        containsPair('protocolVersion', mcpProtocolVersions.first),
      );
      expect(
        await s.handle({
          'jsonrpc': '2.0',
          'method': 'notifications/initialized',
        }),
        isNull,
      );
      expect((await call(s, 'nope'))['error'], containsPair('code', -32601));
      expect(
        (await call(s, 'tools/call', {'name': 'nope'}))['error'],
        containsPair('code', -32602),
      );
    },
  );

  test('read-only by default: run_command needs --allow-write', () async {
    List<Object?> names(Map<String, Object?> response) => [
      for (final t in (response['result']! as Map)['tools'] as List)
        (t as Map)['name'],
    ];
    expect(names(await call(server(), 'tools/list')), [
      'about',
      'routes',
      'schema',
      'conventions',
      'docs_search',
    ]);
    expect(
      names(await call(server(allowWrite: true), 'tools/list')),
      contains('run_command'),
    );
    expect(
      (await call(server(), 'tools/call', {'name': 'run_command'}))['error'],
      isNotNull,
    );
  });

  test('routes carry rules, request schema, response and action', () async {
    final routes =
        (await tool(server(), 'routes', {'method': 'post'}))! as List;
    final store = routes.single as Map<String, Object?>;
    expect(store['uri'], '/api/posts');
    expect(store['name'], 'posts.store');
    expect(store['action'], 'PostController@store');
    expect(store['rules'], {
      'title': ['required', 'string', 'max:120'],
      'email': ['required', 'email'],
    });
    expect(
      ((store['requestSchema']! as Map)['required']! as List),
      containsAll(['title', 'email']),
    );
    expect(store['response'], containsPair('name', 'Post'));
    final show = (await tool(server(), 'routes', {'path': '{post}'}))! as List;
    expect((show.single as Map)['parameters'], ['post']);
  });

  test('schema lists tables and describes one', () async {
    final tables = (await tool(server(), 'schema'))! as List;
    expect(
      tables,
      contains(equals({'table': 'posts', 'columns': '2', 'rows': '0'})),
    );
    final columns =
        (await tool(server(), 'schema', {'table': 'posts'}))! as List;
    expect([for (final c in columns) (c as Map)['column']], ['id', 'title']);
    expect(
      () => tool(server(), 'schema', {'table': 'missing'}),
      throwsA(isA<StateError>()),
    );
  });

  test('conventions and docs_search answer from the bundled guide', () async {
    expect(await tool(server(), 'conventions'), contains('bootstrap/'));
    final hits =
        (await tool(server(), 'docs_search', {'query': 'timezone schedule'}))!
            as List;
    expect(hits, isNotEmpty);
    expect((hits.first as Map)['page'], 'background.md');
    expect(guidePages.keys, containsAll(['index.md', 'orm.md', 'parity.md']));
    expect(
      await tool(server(), 'docs_search', {'query': 'zzqxv nonexistent'}),
      isEmpty,
    );
  });

  test('run_command runs commands, refusing long-running and production '
      'destructive ones', () async {
    final s = server(allowWrite: true);
    expect(
      await tool(s, 'run_command', {
        'command': 'make:model',
        'arguments': ['Post'],
      }),
      {'exitCode': 0, 'stdout': 'ok', 'stderr': ''},
    );
    expect(ran, [
      ['make:model', 'Post'],
    ]);
    expect(
      () => tool(s, 'run_command', {'command': 'serve'}),
      throwsA(isA<StateError>()),
    );
    await app.shutdown();
    app = await boot(env: 'production');
    final prod = server(allowWrite: true);
    await expectLater(
      tool(prod, 'run_command', {'command': 'migrate:fresh'}),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('production'),
        ),
      ),
    );
    expect(ran, hasLength(1));
  });

  test('serve speaks newline-delimited JSON-RPC', () async {
    final input = StreamController<List<int>>();
    final output = _Sink();
    final done = server().serve(input.stream, output);
    input
      ..add(utf8.encode('{"jsonrpc":"2.0","id":7,"method":"ping"}\n'))
      ..add(utf8.encode('not json\n'))
      ..add(
        utf8.encode('{"jsonrpc":"2.0","method":"notifications/initialized"}\n'),
      );
    await input.close();
    await done;
    final lines = [for (final l in output.lines) jsonDecode(l) as Map];
    expect(lines, [
      {'jsonrpc': '2.0', 'id': 7, 'result': <String, Object?>{}},
      {
        'jsonrpc': '2.0',
        'id': null,
        'error': {'code': -32700, 'message': 'Parse error'},
      },
    ]);
  });

  test('rule values render in the rule DSL', () {
    expect(describeRules('required|max:5'), ['required', 'max:5']);
    expect(describeRules(['nullable', Rules.required()]), [
      'nullable',
      'required',
    ]);
    expect(describeRules(Rules.required().min(3)), ['required', 'min:3']);
  });
}

final class _Sink implements IOSink {
  final List<String> lines = [];

  @override
  void writeln([Object? object = '']) => lines.add('$object');

  @override
  Future<void> flush() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
