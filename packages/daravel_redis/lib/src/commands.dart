import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';

import 'client.dart';
import 'config.dart';
import 'resp.dart';
import 'setup.dart';

/// The `redis:*` commands, for `bootstrap/commands.dart`:
///
/// ```dart
/// final List<CommandFactory> commands = [...redisCommands];
/// ```
const List<CommandFactory> redisCommands = [
  RedisPingCommand.new,
  RedisStatsCommand.new,
  RedisKeysAuditCommand.new,
  RedisCliCommand.new,
];

void _connectionOption(DaravelCommand command, [String fallback = 'default']) {
  command.argParser.addOption(
    'connection',
    defaultsTo: fallback,
    help: 'The Redis connection (default, cache).',
  );
}

String _connection(DaravelCommand command) =>
    command.argResults!['connection']! as String;

/// The fields of an `INFO` reply.
Map<String, String> parseRedisInfo(Object? info) => {
  for (final line in LineSplitter.split('${info ?? ''}'))
    if (line.indexOf(':') case final int colon
        when colon > 0 && !line.startsWith('#'))
      line.substring(0, colon): line.substring(colon + 1).trim(),
};

/// `redis:ping [--connection=default]`: the server, its version, the mode
/// and the round trip.
final class RedisPingCommand extends DaravelCommand {
  RedisPingCommand(super.createApp) {
    _connectionOption(this);
  }

  @override
  String get name => 'redis:ping';

  @override
  String get description =>
      'Checks a Redis connection: server, version, mode and latency.';

  @override
  Future<int> run() => withApp((app) async {
    final client = Redis.connection(_connection(this));
    try {
      final watch = Stopwatch()..start();
      final pong = await client.command(['PING']);
      final ms = watch.elapsedMicroseconds / 1000;
      final info = parseRedisInfo(await client.command(['INFO', 'server']));
      final server = info.containsKey('valkey_version')
          ? 'Valkey ${info['valkey_version']}'
          : 'Redis ${info['redis_version'] ?? '?'}';
      stdout.writeln(
        '$pong from ${client.config.redacted} ($server, '
        '${client.config.mode.name}) in ${ms.toStringAsFixed(2)} ms',
      );
      return 0;
    } on RedisConnectionException catch (error) {
      stderr.writeln(error.message);
      return 1;
    }
  });
}

/// `redis:stats [--connection=default]`: what this client did, and what
/// each master reports (`INFO`).
final class RedisStatsCommand extends DaravelCommand {
  RedisStatsCommand(super.createApp) {
    _connectionOption(this);
  }

  @override
  String get name => 'redis:stats';

  @override
  String get description =>
      'Shows a Redis connection: the client and each master (INFO).';

  static const List<String> _fields = [
    'redis_version',
    'valkey_version',
    'uptime_in_seconds',
    'connected_clients',
    'blocked_clients',
    'used_memory_human',
    'maxmemory_human',
    'maxmemory_policy',
    'instantaneous_ops_per_sec',
    'total_commands_processed',
    'keyspace_hits',
    'keyspace_misses',
    'evicted_keys',
    'role',
  ];

  @override
  Future<int> run() => withApp((app) async {
    final client = Redis.connection(_connection(this));
    try {
      final masters = await client.masterClients();
      final report = <String, Object?>{
        'connection': client.config.redacted,
        'masters': {
          for (final master in masters)
            '${master.config.host}:${master.config.port}': {
              for (final MapEntry(:key, :value) in parseRedisInfo(
                await master.command(['INFO']),
              ).entries)
                if (_fields.contains(key)) key: value,
            },
        },
        'client': client.stats,
      };
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
      return 0;
    } on RedisConnectionException catch (error) {
      stderr.writeln(error.message);
      return 1;
    }
  });
}

/// What [auditRedisKeys] found.
typedef RedisKeysAudit = ({
  int keys,
  Map<String, int> types,
  int withoutTtl,
  List<String> cacheWithoutTtl,
});

/// Every key matching [match] (on every master), counted by type, and the
/// keys under [cachePrefix] that never expire, at most [limit] of them:
/// what a cache that only grows looks like.
Future<RedisKeysAudit> auditRedisKeys(
  RedisClient client, {
  required String match,
  required String cachePrefix,
  int limit = 20,
}) async {
  var keys = 0;
  var withoutTtl = 0;
  final types = <String, int>{};
  final cacheWithoutTtl = <String>[];
  final batch = <String>[];
  Future<void> inspect() async {
    final replies = await client.pipeline([
      for (final key in batch) ...[
        ['TYPE', key],
        ['PTTL', key],
      ],
    ]);
    for (var i = 0; i < batch.length; i++) {
      final type = '${replies[i * 2]}';
      types[type] = (types[type] ?? 0) + 1;
      if (replies[i * 2 + 1] == -1) {
        withoutTtl++;
        if (batch[i].startsWith(cachePrefix) &&
            cacheWithoutTtl.length < limit) {
          cacheWithoutTtl.add(batch[i]);
        }
      }
    }
    keys += batch.length;
    batch.clear();
  }

  await for (final key in client.scan(match: match)) {
    batch.add(key);
    if (batch.length >= 200) {
      await inspect();
    }
  }
  if (batch.isNotEmpty) {
    await inspect();
  }
  return (
    keys: keys,
    types: types,
    withoutTtl: withoutTtl,
    cacheWithoutTtl: cacheWithoutTtl,
  );
}

/// `redis:keys-audit [--connection=cache] [--match=...] [--limit=20]`:
/// keys by type under the application's prefix, and cache keys without a
/// time to live (they stay until deleted).
final class RedisKeysAuditCommand extends DaravelCommand {
  RedisKeysAuditCommand(super.createApp) {
    _connectionOption(this, 'cache');
    argParser
      ..addOption(
        'match',
        help: 'A SCAN pattern (default: everything under REDIS_PREFIX).',
      )
      ..addOption('limit', defaultsTo: '20', help: 'Cache keys to list.');
  }

  @override
  String get name => 'redis:keys-audit';

  @override
  String get description =>
      'Counts keys by type and lists cache keys that never expire.';

  @override
  Future<int> run() => withApp((app) async {
    final config = App.make<ConfigRepository>();
    final redis = config.section<RedisConfig>();
    final cachePrefix =
        '${redis.prefix}${config.section<CacheConfig>().prefix}';
    final match = argResults!['match'] as String? ?? '${redis.prefix}*';
    final audit = await auditRedisKeys(
      Redis.connection(_connection(this)),
      match: match,
      cachePrefix: cachePrefix,
      limit: int.tryParse(argResults!['limit']! as String) ?? 20,
    );
    stdout.writeln('${audit.keys} keys match $match');
    for (final MapEntry(key: type, value: count) in audit.types.entries) {
      stdout.writeln('  $type: $count');
    }
    stdout.writeln('${audit.withoutTtl} without a time to live');
    if (audit.cacheWithoutTtl.isNotEmpty) {
      stdout.writeln('Cache keys that never expire (forever(), or a leak):');
      for (final key in audit.cacheWithoutTtl) {
        stdout.writeln('  $key');
      }
    }
    return 0;
  });
}

/// Commands `redis:cli` runs without `--write`: those that only read
/// (`KEYS` is left out: it blocks the server on a large database, `SCAN`
/// does not).
const Set<String> redisReadCommands = {
  'GET', 'MGET', 'STRLEN', 'GETRANGE', 'EXISTS', 'TYPE', 'TTL', 'PTTL', //
  'EXPIRETIME', 'PEXPIRETIME', 'SCAN', 'DBSIZE', 'RANDOMKEY', //
  'HGET', 'HMGET', 'HGETALL', 'HKEYS', 'HVALS', 'HLEN', 'HEXISTS', 'HSCAN',
  'HSTRLEN', 'LRANGE', 'LLEN', 'LINDEX', 'LPOS', //
  'SMEMBERS', 'SISMEMBER', 'SMISMEMBER', 'SCARD', 'SSCAN', 'SRANDMEMBER',
  'ZRANGE', 'ZRANGEBYSCORE', 'ZREVRANGE', 'ZREVRANGEBYSCORE', 'ZSCORE',
  'ZMSCORE', 'ZCARD', 'ZCOUNT', 'ZRANK', 'ZREVRANK', 'ZSCAN', //
  'XLEN', 'XRANGE', 'XREVRANGE', 'XINFO', 'XPENDING', //
  'PFCOUNT', 'BITCOUNT', 'GETBIT', //
  'PING', 'ECHO', 'INFO', 'TIME', 'ROLE', 'LASTSAVE', 'PUBSUB',
};

/// Read-only subcommands of commands that can also write.
const Map<String, Set<String>> _readSubcommands = {
  'CLUSTER': {
    'INFO', 'SLOTS', 'SHARDS', 'NODES', 'KEYSLOT', 'COUNTKEYSINSLOT', //
    'MYID', 'MYSHARDID',
  },
  'CLIENT': {'LIST', 'INFO', 'ID', 'GETNAME'},
  'CONFIG': {'GET'},
  'MEMORY': {'USAGE', 'STATS', 'DOCTOR'},
  'OBJECT': {'ENCODING', 'FREQ', 'IDLETIME', 'REFCOUNT'},
  'SLOWLOG': {'GET', 'LEN'},
  'LATENCY': {'LATEST', 'HISTORY', 'DOCTOR'},
  'SCRIPT': {'EXISTS'},
  'COMMAND': {'COUNT', 'INFO', 'DOCS', 'GETKEYS'},
};

/// Whether [args] only reads.
bool isReadOnlyRedisCommand(List<String> args) {
  if (args.isEmpty) {
    return false;
  }
  final name = args.first.toUpperCase();
  if (redisReadCommands.contains(name)) {
    return true;
  }
  final subcommands = _readSubcommands[name];
  return subcommands != null &&
      args.length > 1 &&
      subcommands.contains(args[1].toUpperCase());
}

/// A command line split as `redis-cli` does: on spaces, with `"..."` and
/// `'...'` quoting (backslash escapes inside double quotes).
List<String> parseRedisCommandLine(String line) {
  final args = <String>[];
  final current = StringBuffer();
  var quote = '';
  var started = false;
  for (var i = 0; i < line.length; i++) {
    final char = line[i];
    if (quote.isNotEmpty) {
      if (char == quote) {
        quote = '';
      } else if (char == r'\' && quote == '"' && i + 1 < line.length) {
        final next = line[++i];
        current.write(switch (next) {
          'n' => '\n',
          'r' => '\r',
          't' => '\t',
          _ => next,
        });
      } else {
        current.write(char);
      }
    } else if (char == '"' || char == "'") {
      quote = char;
      started = true;
    } else if (char == ' ' || char == '\t') {
      if (started) {
        args.add(current.toString());
        current.clear();
        started = false;
      }
    } else {
      current.write(char);
      started = true;
    }
  }
  if (quote.isNotEmpty) {
    throw const FormatException('Unbalanced quotes.');
  }
  if (started) {
    args.add(current.toString());
  }
  return args;
}

/// A reply as `redis-cli` prints it.
String formatRedisReply(Object? reply, [String indent = '']) => switch (reply) {
  null => '(nil)',
  final int number => '(integer) $number',
  final double number => '(double) $number',
  final bool flag => '(boolean) $flag',
  final RedisCommandException error => '(error) ${error.message}',
  final String text => jsonEncode(text),
  final List<Object?> items when items.isEmpty => '(empty array)',
  final List<Object?> items => [
    for (var i = 0; i < items.length; i++)
      '${i == 0 ? '' : indent}${i + 1}) '
          '${formatRedisReply(items[i], '$indent${' ' * '${i + 1}) '.length}')}',
  ].join('\n'),
  final Map<Object?, Object?> map => formatRedisReply([
    for (final MapEntry(:key, :value) in map.entries) ...[key, value],
  ], indent),
  _ => '$reply',
};

/// `redis:cli [--connection=default] [--write] [command ...]`: one command,
/// or a prompt reading commands until `quit`. Only reading commands run
/// unless `--write` is given.
final class RedisCliCommand extends DaravelCommand {
  RedisCliCommand(super.createApp) {
    _connectionOption(this);
    argParser.addFlag(
      'write',
      negatable: false,
      help: 'Also run commands that write or reconfigure.',
    );
  }

  @override
  String get name => 'redis:cli';

  @override
  String get description => 'Runs Redis commands (read-only unless --write).';

  @override
  Future<int> run() => withApp((app) async {
    final client = Redis.connection(_connection(this));
    final write = argResults!['write'] == true;
    Future<bool> execute(List<String> args) async {
      if (!write && !isReadOnlyRedisCommand(args)) {
        stderr.writeln(
          '${args.first.toUpperCase()} is not a read-only command; '
          'run redis:cli --write to allow it.',
        );
        return false;
      }
      try {
        stdout.writeln(formatRedisReply(await client.command(args)));
        return true;
      } on RedisCommandException catch (error) {
        stdout.writeln(formatRedisReply(error));
        return false;
      }
    }

    final rest = argResults!.rest;
    if (rest.isNotEmpty) {
      return await execute(rest) ? 0 : 1;
    }
    stdout.writeln(
      'Connected to ${client.config.redacted}'
      '${write ? '' : ' (read-only)'}; quit to leave.',
    );
    while (true) {
      stdout.write('redis> ');
      final line = stdin.readLineSync();
      if (line == null || line.trim().toLowerCase() == 'quit') {
        return 0;
      }
      try {
        final args = parseRedisCommandLine(line);
        if (args.isNotEmpty) {
          await execute(args);
        }
      } on FormatException catch (error) {
        stderr.writeln(error.message);
      }
    }
  });
}
