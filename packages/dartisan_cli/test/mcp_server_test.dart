import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:dartisan_cli/src/guide_pages.g.dart';
import 'package:test/test.dart';

final class Post extends Model {
  static final ModelDefinition<Post> definition = ModelDefinition<Post>(
    table: 'posts',
    factory: Post.new,
    fillable: ['title'],
    timestamps: false,
    relations: {
      'comments': () =>
          HasMany<Comment>(() => Comment.definition, foreignKey: 'post_id'),
    },
  );
  @override
  ModelDefinition<Post> get modelDefinition => Post.definition;
}

final class Comment extends Model {
  static final ModelDefinition<Comment> definition = ModelDefinition<Comment>(
    table: 'comments',
    factory: Comment.new,
  );
  @override
  ModelDefinition<Comment> get modelDefinition => Comment.definition;
}

void main() {
  late Application app;
  final logs = Directory.systemTemp.createTempSync('mcp_logs_');
  tearDownAll(() => logs.deleteSync(recursive: true));
  final ran = <List<String>>[];

  Future<Application> boot({String env = 'local'}) async {
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': env,
          'APP_KEY': 'base64:${base64Encode(List.filled(32, 7))}',
          'DB_DATABASE': ':memory:',
          'LOG_PATH': logs.path,
        })
        .withModels([Post.definition, Comment.definition])
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
      'models',
      'db_query',
      'read_logs',
      'last_error',
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

  test('models lists the registry and describes one model', () async {
    expect(await tool(server(), 'models'), [
      {
        'class': 'Post',
        'table': 'posts',
        'relations': {'comments': 'HasMany'},
      },
      {
        'class': 'Comment',
        'table': 'comments',
        'relations': <String, Object?>{},
      },
    ]);
    final post = (await tool(server(), 'models', {'model': 'post'}))! as Map;
    expect(post['class'], 'Post');
    expect(post['attributes'], [
      {
        'name': 'id',
        'type': 'INTEGER',
        'nullable': true,
        'default': null,
        'primary': false,
        'increments': false,
        'fillable': false,
        'hidden': false,
        'cast': null,
      },
      {
        'name': 'title',
        'type': 'TEXT',
        'nullable': true,
        'default': null,
        'primary': false,
        'increments': false,
        'fillable': true,
        'hidden': false,
        'cast': null,
      },
    ]);
    expect(
      (post['relations']! as List).single,
      containsPair('related', 'Comment'),
    );
    // Comment has no table yet: no attributes, no error.
    final comment =
        (await tool(server(), 'models', {'model': 'Comment'}))! as Map;
    expect(comment['attributes'], isEmpty);
    expect(
      () => tool(server(), 'models', {'model': 'Nope'}),
      throwsA(isA<StateError>()),
    );
  });

  test('db_query runs read-only selects through the tool', () async {
    await app.run(() => DB.table('posts').insert({'id': 1, 'title': 'Hello'}));
    expect(
      await tool(server(), 'db_query', {
        'sql': 'SELECT title FROM posts WHERE id = ?',
        'bindings': [1],
      }),
      {
        'rows': [
          {'title': 'Hello'},
        ],
        'truncated': false,
      },
    );
    expect(
      () => tool(server(), 'db_query', {'sql': 'DELETE FROM posts'}),
      throwsA(isA<StateError>()),
    );
  });

  test('read_logs and last_error read the daily log files', () async {
    expect(await tool(server(), 'last_error'), startsWith('No error'));
    final day = File('${logs.path}/daravel-2026-10-24.log');
    final today = File('${logs.path}/daravel-2026-10-25.log');
    day.writeAsStringSync(
      '{"time":"2026-10-24T10:00:00Z","level":"error","message":"old"}\n',
    );
    today.writeAsStringSync(
      '{"time":"2026-10-25T09:00:00Z","level":"info","message":"one"}\n'
      'not json\n'
      '{"time":"2026-10-25T09:01:00Z","level":"error","message":"boom",'
      '"error":"StateError"}\n'
      '{"time":"2026-10-25T09:02:00Z","level":"debug","message":"two"}\n',
    );
    final messages = [
      for (final r in (await tool(server(), 'read_logs'))! as List)
        (r as Map)['message'],
    ];
    expect(messages, ['old', 'one', 'boom', 'two']);
    expect(
      [
        for (final r
            in (await tool(server(), 'read_logs', {'count': 2}))! as List)
          (r as Map)['message'],
      ],
      ['boom', 'two'],
    );
    expect(
      [
        for (final r
            in (await tool(server(), 'read_logs', {'level': 'warning'}))!
                as List)
          (r as Map)['message'],
      ],
      ['old', 'boom'],
    );
    expect(await tool(server(), 'last_error'), containsPair('message', 'boom'));
  });

  test('conventions and docs_search answer from the bundled guide', () async {
    expect(await tool(server(), 'conventions'), contains('bootstrap/'));
    final hits =
        (await tool(server(), 'docs_search', {'query': 'timezone schedule'}))!
            as List;
    expect(hits, isNotEmpty);
    expect((hits.first as Map)['page'], 'background.md');
    expect(
      guidePages.keys,
      containsAll(['index.md', 'orm.md', 'parity.md', 'id/index.md']),
    );
    // Indonesian pages only with locale id.
    expect(
      await tool(server(), 'docs_search', {'query': 'berdampingan'}),
      isEmpty,
    );
    final id =
        (await tool(server(), 'docs_search', {
              'query': 'berdampingan',
              'locale': 'id',
            }))!
            as List;
    expect([
      for (final h in id) (h as Map)['page'],
    ], everyElement(startsWith('id/')));
    expect(id, isNotEmpty);
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
  test('packages add tools through their commands', () async {
    final runner = CommandRunner<int>('dartisan', 'test')
      ..addCommand(_ToolCommand());
    final tools = mcpToolsOf(runner);
    expect([for (final t in tools) t.name], ['echo', 'wipe']);

    Future<List<Object?>> listed(McpServer server) async {
      final result =
          (await call(server, 'tools/list'))['result']! as Map<String, Object?>;
      return [
        for (final t in result['tools']! as List<Object?>)
          (t! as Map<String, Object?>)['name'],
      ];
    }

    final readOnly = McpServer(app, tools: tools);
    expect(await listed(readOnly), contains('echo'));
    expect(await listed(readOnly), isNot(contains('wipe')));
    expect(await tool(readOnly, 'echo', {'text': 'hi'}), {'echo': 'hi'});
    final writing = McpServer(app, allowWrite: true, tools: tools);
    expect(await listed(writing), containsAll(['echo', 'wipe']));
    expect(await tool(writing, 'wipe'), 'wiped');
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

final class _ToolCommand extends Command<int> implements McpToolSource {
  @override
  String get name => 'tool:test';

  @override
  String get description => 'Brings tools.';

  @override
  List<McpTool> get mcpTools => [
    McpTool(
      name: 'echo',
      description: 'Echoes.',
      properties: const {
        'text': {'type': 'string'},
      },
      run: (arguments) async => {'echo': arguments['text']},
    ),
    McpTool(
      name: 'wipe',
      description: 'Writes.',
      readOnly: false,
      run: (arguments) async => 'wiped',
    ),
  ];
}
