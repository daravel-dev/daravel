import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';

import 'config.dart';
import 'server.dart';

/// The `reverb:*` commands, for `bootstrap/commands.dart`:
///
/// ```dart
/// final List<CommandFactory> commands = [...reverbCommands];
/// ```
const List<CommandFactory> reverbCommands = [
  ReverbStartCommand.new,
  ReverbRestartCommand.new,
  ReverbStatsCommand.new,
];

/// `reverb:start`: the Pusher server in a process of its own, as Laravel's
/// `php artisan reverb:start`. It serves the application's broadcasting
/// only (`/app/{key}`, `/apps/{id}/*`, `/broadcasting/auth` with
/// `REVERB_SERVER_AUTH=local`), `/up`, `/up/ready` and `/metrics`, in
/// `REVERB_SERVER_ISOLATES` worker isolates.
final class ReverbStartCommand extends DaravelCommand {
  /// The `dartisan reverb:start` command.
  ReverbStartCommand(super.createApp) {
    argParser
      ..addOption('host', help: 'The address (REVERB_SERVER_HOST, 0.0.0.0).')
      ..addOption('port', help: 'The port (REVERB_SERVER_PORT, 8080).')
      ..addOption(
        'path',
        help: 'The prefix of the Pusher routes (REVERB_SERVER_PATH).',
      )
      ..addOption(
        'hostname',
        help: 'The public host name, for the address printed (REVERB_HOST).',
      )
      ..addOption(
        'isolates',
        help: 'Worker isolates (REVERB_SERVER_ISOLATES, the processors).',
      )
      ..addFlag(
        'debug',
        negatable: false,
        help: 'Log every frame, signatures masked.',
      );
  }

  @override
  String get name => 'reverb:start';

  @override
  String get description => 'Starts the Reverb (Pusher protocol) server.';

  @override
  Future<int> run() async {
    final results = argResults!;
    int? number(String option, {int min = 0}) {
      final value = results[option] as String?;
      if (value == null) {
        return null;
      }
      final parsed = int.tryParse(value);
      if (parsed == null || parsed < min) {
        usageException('--$option must be an integer of at least $min.');
      }
      return parsed;
    }

    final port = number('port');
    final isolates = number('isolates', min: 1);
    ReverbConfig? config;
    String? problem;
    await withApp((app) async {
      try {
        config = app.config.section<ReverbConfig>();
      } on Object {
        problem =
            'Reverb is not registered: add .withReverb() to '
            'bootstrap/app.dart.';
        return 1;
      }
      if (app.container.make<BroadcastManager>().server == null) {
        problem =
            'No Pusher server to start: add .withBroadcasting() and '
            'set REVERB_APP_ID, REVERB_APP_KEY and REVERB_APP_SECRET (or '
            'REVERB_APPS).';
      }
      return 0;
    });
    final settings = config;
    if (problem != null || settings == null) {
      stderr.writeln(problem);
      return 1;
    }
    final path = _path(results['path'] as String? ?? settings.path);
    final host = results['host'] as String? ?? settings.host;
    final bound = port ?? settings.port;
    final hostname =
        results['hostname'] as String? ?? settings.hostname ?? host;
    stdout.writeln(
      'Reverb: ws://$hostname:$bound$path/app/{key} '
      '(${isolates ?? settings.isolates} isolates; Ctrl+C to stop).',
    );
    return Application.serveWith(
      reverbServer(
        createApp,
        path: path,
        auth: settings.auth == ReverbAuth.local,
        debug: results['debug'] as bool,
      ),
      host: host,
      port: bound,
      isolates: isolates ?? settings.isolates,
      // A WebSocket server only: what SERVER_EMBED_* or APP_PROCESSES say
      // is for `serve`.
      embedQueue: false,
      embedScheduler: false,
      embedWorkers: const [],
      processes: 1,
    );
  }

  String _path(String path) {
    if (path.isEmpty || path == '/') {
      return '';
    }
    final trimmed = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    return trimmed.startsWith('/') ? trimmed : '/$trimmed';
  }
}

/// `reverb:restart`: every `reverb:start` isolate sharing the queue's
/// signal store drains its connections (spread over `REVERB_DRAIN_SPREAD`)
/// and starts again; clients reconnect with their own backoff.
final class ReverbRestartCommand extends DaravelCommand {
  /// The `dartisan reverb:restart` command.
  ReverbRestartCommand(super.createApp);

  @override
  String get name => 'reverb:restart';

  @override
  String get description =>
      'Restarts the Reverb servers after their connections drain.';

  @override
  Future<int> run() => withApp((app) async {
    if (!await requestReverbRestart(app)) {
      stderr.writeln(
        'The queue has no signal store (QUEUE_SIGNAL_STORE): nothing to '
        'tell the servers through.',
      );
      return 1;
    }
    stdout.writeln('Broadcasting Reverb restart signal.');
    return 0;
  });
}

/// `reverb:stats [--url] [--token] [--json]`: connections, channels and
/// messages of a running Reverb server, per isolate and in total, read
/// from its `/metrics` (`METRICS_ENABLED=true`).
final class ReverbStatsCommand extends DaravelCommand {
  /// The `dartisan reverb:stats` command.
  ReverbStatsCommand(super.createApp) {
    argParser
      ..addOption(
        'url',
        help:
            "The server's metrics, by default "
            'http://127.0.0.1:<REVERB_SERVER_PORT><METRICS_PATH>.',
      )
      ..addOption('token', help: 'The metrics token (METRICS_TOKEN).')
      ..addFlag('json', negatable: false, help: 'Print JSON.');
  }

  @override
  String get name => 'reverb:stats';

  @override
  String get description => 'Shows the connections of a running Reverb.';

  @override
  Future<int> run() => withApp((app) async {
    final results = argResults!;
    final metrics = app.config.section<MetricsConfig>();
    final url =
        results['url'] as String? ??
        'http://127.0.0.1:${app.config.section<ReverbConfig>().port}'
            '${metrics.path}';
    final token = results['token'] as String? ?? metrics.token;
    var request = Http.timeout(const Duration(seconds: 10));
    if (token != null && token.isNotEmpty) {
      request = request.withToken(token);
    }
    final ClientResponse response;
    try {
      response = await request.get(url);
    } on ConnectionException catch (error) {
      stderr.writeln('Cannot reach $url: ${error.message}');
      return 1;
    }
    if (!response.successful) {
      stderr.writeln(
        '$url answered ${response.status}'
        '${response.status == 401 ? ': pass --token (METRICS_TOKEN)' : ''}'
        '${response.status == 404 ? ': is METRICS_ENABLED=true?' : ''}.',
      );
      return 1;
    }
    final report = ReverbReport.parse(response.body);
    if (results['json'] as bool) {
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
      );
    } else {
      stdout.write(report.table());
    }
    return 0;
  });
}

/// The `reverb_*` series of a `/metrics` response, as `reverb:stats`
/// prints them.
final class ReverbReport {
  /// A report.
  const ReverbReport({
    required this.connections,
    required this.channels,
    required this.messages,
    required this.rejected,
  });

  /// Reads the `reverb_*` series of Prometheus text.
  factory ReverbReport.parse(String metrics) {
    final connections = <String, Map<String, int>>{};
    final channels = <String, Map<String, int>>{};
    final messages = <String, Map<String, int>>{};
    final rejected = <String, int>{};
    final line = RegExp(r'^([a-z_]+)(?:\{([^}]*)\})?\s+(\S+)$');
    final label = RegExp(r'([a-z_]+)="((?:[^"\\]|\\.)*)"');
    void add(Map<String, Map<String, int>> into, String a, String b, int n) {
      final row = into.putIfAbsent(a, () => {});
      row[b] = (row[b] ?? 0) + n;
    }

    for (final raw in metrics.split('\n')) {
      final match = line.firstMatch(raw.trim());
      if (match == null || !match[1]!.startsWith('reverb_')) {
        continue;
      }
      final labels = {
        for (final l in label.allMatches(match[2] ?? '')) l[1]!: l[2]!,
      };
      final value = (double.tryParse(match[3]!) ?? 0).round();
      final app = labels['app'] ?? '';
      switch (match[1]) {
        case 'reverb_connections':
          add(connections, app, labels['worker'] ?? '', value);
        case 'reverb_channels':
          add(channels, app, labels['type'] ?? '', value);
        case 'reverb_messages_total':
          add(messages, app, labels['direction'] ?? '', value);
        case 'reverb_rejected_total':
          final reason = labels['reason'] ?? '';
          rejected[reason] = (rejected[reason] ?? 0) + value;
      }
    }
    return ReverbReport(
      connections: connections,
      channels: channels,
      messages: messages,
      rejected: rejected,
    );
  }

  /// Open connections, by app and worker isolate.
  final Map<String, Map<String, int>> connections;

  /// Subscriptions, by app and channel type.
  final Map<String, Map<String, int>> channels;

  /// Messages since the server started, by app and direction (`in`,
  /// `out`).
  final Map<String, Map<String, int>> messages;

  /// Refusals since the server started, by reason.
  final Map<String, int> rejected;

  /// Every app the report names.
  List<String> get apps =>
      {...connections.keys, ...channels.keys, ...messages.keys}.toList()
        ..sort();

  /// Open connections of [app], every isolate together.
  int connectionsOf(String app) =>
      connections[app]?.values.fold<int>(0, (a, b) => a + b) ?? 0;

  /// As JSON.
  Map<String, Object?> toJson() => {
    'apps': {
      for (final app in apps)
        app: {
          'connections': connectionsOf(app),
          'workers': connections[app] ?? const <String, int>{},
          'channels': channels[app] ?? const <String, int>{},
          'messages_in': messages[app]?['in'] ?? 0,
          'messages_out': messages[app]?['out'] ?? 0,
        },
    },
    'rejected': rejected,
  };

  /// As the table `reverb:stats` prints.
  String table() {
    if (apps.isEmpty) {
      return 'No Pusher connections reported.\n';
    }
    final out = StringBuffer();
    for (final app in apps) {
      final kinds = channels[app] ?? const <String, int>{};
      out.writeln(
        'App $app: ${connectionsOf(app)} connections, '
        '${kinds.isEmpty ? 'no channels' : kinds.entries.map((e) => '${e.value} ${e.key}').join(', ')}, '
        '${messages[app]?['in'] ?? 0} messages in, '
        '${messages[app]?['out'] ?? 0} out',
      );
      final workers =
          (connections[app] ?? const <String, int>{}).entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key));
      for (final worker in workers) {
        out.writeln('  ${worker.key.padRight(20)} ${worker.value}');
      }
    }
    if (rejected.isNotEmpty) {
      out.writeln(
        'Refused: ${rejected.entries.map((e) => '${e.key} ${e.value}').join(', ')}',
      );
    }
    return out.toString();
  }
}
