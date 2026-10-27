import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart' show daravelVersion;
import 'package:path/path.dart' as p;

import 'db_install.dart';
import 'generator.dart';

const DriverPackage _redis = DriverPackage(
  package: 'daravel_redis',
  title: 'Redis',
  connection: 'redis',
  note: 'CACHE_STORE=redis, QUEUE_CONNECTION=redis, ...',
  registration: ['.withRedis()'],
  env: [
    'REDIS_HOST=127.0.0.1',
    'REDIS_PORT=6379',
    'REDIS_PASSWORD=',
    'CACHE_STORE=redis',
    'CACHE_LIMITER=redis',
    'QUEUE_CONNECTION=redis',
  ],
);

/// The compose files `redis:install --docker` looks for, in order.
const List<String> composeFiles = [
  'compose.yaml',
  'compose.yml',
  'docker-compose.yml',
  'docker-compose.yaml',
];

/// [compose] (empty: a new file) with a [server] service (`valkey` or
/// `redis`) and its volume, or unchanged when it runs Redis or Valkey
/// already.
String addRedisService(String compose, {String server = 'valkey'}) {
  if (RegExp(
    r"""^\s+image:\s*["']?(\S*/)?(valkey|redis)[:@\s"']""",
    multiLine: true,
  ).hasMatch(compose)) {
    return compose;
  }
  final image = server == 'redis' ? 'redis:7' : 'valkey/valkey:8';
  final service = [
    '  $server:',
    '    image: $image',
    '    ports:',
    '      - "127.0.0.1:6379:6379"',
    '    volumes:',
    '      - $server-data:/data',
    '    healthcheck:',
    '      test: ["CMD", "${server == 'redis' ? 'redis' : 'valkey'}-cli", "ping"]',
    '      interval: 5s',
  ].join('\n');
  if (compose.trim().isEmpty) {
    return 'services:\n$service\n\nvolumes:\n  $server-data:\n';
  }
  var result = compose.endsWith('\n') ? compose : '$compose\n';
  final services = RegExp(
    r'^services:[ \t]*\r?\n',
    multiLine: true,
  ).firstMatch(result);
  if (services == null) {
    result = '${result}services:\n$service\n';
  } else {
    result = result.replaceRange(services.end, services.end, '$service\n');
  }
  final volumes = RegExp(
    r'^volumes:[ \t]*\r?\n',
    multiLine: true,
  ).firstMatch(result);
  return volumes == null
      ? '$result\nvolumes:\n  $server-data:\n'
      : result.replaceRange(volumes.end, volumes.end, '  $server-data:\n');
}

/// `redis:install [--docker] [--server=valkey|redis]`: adds daravel_redis
/// to the project, registers `.withRedis()` and its commands, documents its
/// `.env` keys and, with `--docker`, a Valkey (or Redis) service.
final class RedisInstallCommand extends Command<int> {
  RedisInstallCommand() {
    argParser
      ..addFlag(
        'docker',
        negatable: false,
        help: 'Add a Valkey (or Redis) service to the compose file.',
      )
      ..addOption(
        'server',
        allowed: ['valkey', 'redis'],
        defaultsTo: 'valkey',
        help: 'The server --docker adds (Valkey is BSD-licensed).',
      )
      ..addFlag(
        'get',
        defaultsTo: true,
        help: 'Run `dart pub get` afterwards.',
      );
  }

  @override
  String get name => 'redis:install';

  @override
  String get description =>
      'Add Redis or Valkey (daravel_redis) for several servers.';

  @override
  Future<int> run() async {
    final root = ProjectPaths.locate().root;
    final changed = <String>[];
    void update(String path, String Function(String text) change, String why) {
      final file = File(p.join(root, path));
      final before = file.existsSync() ? file.readAsStringSync() : '';
      final after = change(before);
      if (after != before) {
        file.writeAsStringSync(after);
        changed.add('$path ($why)');
      }
    }

    update(
      'pubspec.yaml',
      (text) => addDependency(text, _redis.package, '^$daravelVersion'),
      '${_redis.package}: ^$daravelVersion',
    );
    final bootstrap = File(p.join(root, 'bootstrap', 'app.dart'));
    if (bootstrap.existsSync()) {
      final source = bootstrap.readAsStringSync();
      if (registerDriver(source, _redis) == null) {
        stderr.writeln(
          'bootstrap/app.dart has no Application.configure(...); add '
          '.withRedis() and ${_redis.import} by hand.',
        );
      } else {
        update(
          'bootstrap/app.dart',
          (text) => registerDriver(text, _redis)!,
          '.withRedis()',
        );
      }
    }
    final commands = File(p.join(root, 'bootstrap', 'commands.dart'));
    if (commands.existsSync()) {
      update(
        'bootstrap/commands.dart',
        (text) =>
            RegistryPatcher.patch(
              text,
              importLine: "import 'package:daravel_redis/commands.dart';",
              entryLine: '  ...redisCommands,',
            ) ??
            text,
        'redis:* commands',
      );
    }
    update('.env.example', (text) => addEnvExample(text, _redis), 'Redis keys');
    if (argResults!['docker'] == true) {
      final compose = composeFiles.firstWhere(
        (name) => File(p.join(root, name)).existsSync(),
        orElse: () => composeFiles.first,
      );
      final server = argResults!['server']! as String;
      update(
        compose,
        (text) => addRedisService(text, server: server),
        '$server service',
      );
    }

    if (changed.isEmpty) {
      stdout.writeln('Redis is already installed.');
      return 0;
    }
    for (final line in changed) {
      stdout.writeln('Updated $line');
    }
    if (argResults!['get'] == true) {
      final dart = Platform.resolvedExecutable;
      final get = await Process.run(dart, [
        'pub',
        'get',
      ], workingDirectory: root);
      if (get.exitCode != 0) {
        stderr
          ..write(get.stdout)
          ..write(get.stderr);
        return get.exitCode;
      }
      await Process.run(dart, ['format', p.join(root, 'bootstrap')]);
    }
    stdout.writeln(
      'Set REDIS_HOST (or REDIS_URL) and choose what goes to Redis in .env: '
      'CACHE_STORE=redis, CACHE_LIMITER=redis, QUEUE_CONNECTION=redis. On '
      'one server Daravel does not need Redis.',
    );
    return 0;
  }
}
