import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Smoke test for the compiled server binary:
/// `dart run tool/smoke.dart [path/to/server]`.
///
/// Starts the binary on a random port with an in-memory database, waits for
/// `/up`, checks `/api/ping`, then stops the process. Exit code 0 = success.
Future<void> main(List<String> args) async {
  final binary = args.isNotEmpty
      ? args.first
      : (Platform.isWindows
            ? 'build/server/bundle/bin/server.exe'
            : 'build/server/bundle/bin/server');
  if (!File(binary).existsSync()) {
    stderr.writeln(
      'Binary not found: $binary '
      '(run `dart build cli -t bin/server.dart -o build/server`).',
    );
    exitCode = 2;
    return;
  }

  final port = 18000 + Random().nextInt(2000);
  final process = await Process.start(
    File(binary).absolute.path,
    const <String>[],
    environment: <String, String>{
      'APP_ENV': 'production',
      'APP_DEBUG': 'false',
      'APP_HOST': '127.0.0.1',
      'APP_PORT': '$port',
      'DB_DATABASE': ':memory:',
    },
  );
  process.stdout.transform(utf8.decoder).listen(stdout.write);
  process.stderr.transform(utf8.decoder).listen(stderr.write);

  final client = HttpClient();
  var ok = false;
  try {
    final base = Uri.parse('http://127.0.0.1:$port');
    final up = await _waitFor(client, base.resolve('/up'));
    if (up == null) {
      stderr.writeln('SMOKE FAIL: /up did not answer within the timeout.');
      return;
    }
    if (up.statusCode != 200 ||
        (jsonDecode(up.body) as Map<String, Object?>)['status'] != 'ok') {
      stderr.writeln('SMOKE FAIL: /up returned ${up.statusCode} ${up.body}');
      return;
    }
    final ping = await _fetch(client, base.resolve('/api/ping'));
    final payload = jsonDecode(ping.body) as Map<String, Object?>;
    if (ping.statusCode != 200 || payload['message'] != 'pong') {
      stderr.writeln(
        'SMOKE FAIL: /api/ping returned ${ping.statusCode} ${ping.body}',
      );
      return;
    }
    final missing = await _fetch(client, base.resolve('/api/nope'));
    if (missing.statusCode != 404) {
      stderr.writeln('SMOKE FAIL: /api/nope returned ${missing.statusCode}');
      return;
    }
    ok = true;
    stdout.writeln(
      'SMOKE OK: /up, /api/ping and 404 handling verified on port $port.',
    );
  } finally {
    client.close(force: true);
    // Windows cannot deliver SIGINT to another process; terminate directly there.
    process.kill(
      Platform.isWindows ? ProcessSignal.sigterm : ProcessSignal.sigint,
    );
    final exit = await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    stdout.writeln('Server exited with code $exit.');
    exitCode = ok ? 0 : 1;
  }
}

Future<_Reply?> _waitFor(HttpClient client, Uri uri) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    try {
      return await _fetch(client, uri);
    } on SocketException {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  return null;
}

Future<_Reply> _fetch(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri);
  request.headers.set('accept', 'application/json');
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  return _Reply(response.statusCode, body);
}

final class _Reply {
  const _Reply(this.statusCode, this.body);

  final int statusCode;
  final String body;
}
