import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_reverb/daravel_reverb.dart';
import 'package:test/test.dart';

final String longSecret = 's' * 32;

Iterable<ConfigIssue> check(Map<String, String> env) {
  final values = Env.fromMap(env);
  final config = ConfigRepository()
    ..register<ReverbConfig>(ReverbConfig.fromEnv(values))
    ..register<BroadcastConfig>(BroadcastConfig.fromEnv(values));
  return ReverbConfig.check(values, config);
}

void main() {
  test("defaults are Reverb's", () {
    final config = ReverbConfig.fromEnv(
      Env.fromMap({'REVERB_SERVER_ISOLATES': '2'}),
    );
    expect(config.host, '0.0.0.0');
    expect(config.port, 8080);
    expect(config.path, '');
    expect(config.isolates, 2);
    expect(config.auth, ReverbAuth.app);
    expect(config.source, ReverbAppsSource.config);
    expect(config.apps, isEmpty);
    expect(config.appsCacheTtl, const Duration(seconds: 60));
  });

  test('REVERB_APPS takes the entries of config/reverb.php', () {
    final config = ReverbConfig.fromEnv(
      Env.fromMap({
        'REVERB_SERVER_AUTH': 'local',
        'REVERB_APPS_PROVIDER': 'database',
        'REVERB_APPS': jsonEncode([
          {
            'app_id': 1001,
            'key': 'tenant-a',
            'secret': longSecret,
            'allowed_origins': ['a.example.com'],
            'max_connections': 5,
            'max_message_size': 2048,
            'activity_timeout': 45,
            'rate_limiting': {
              'enabled': true,
              'max_attempts': 10,
              'decay_seconds': 5,
              'terminate_on_limit': true,
            },
            'encryption_master_key': base64.encode(List.filled(32, 1)),
          },
          {'app_id': 'b', 'key': 'tenant-b', 'secret': 'short'},
        ]),
      }),
    );
    expect(config.auth, ReverbAuth.local);
    expect(config.source, ReverbAppsSource.database);
    final [a, b] = config.apps;
    expect(a.id, '1001');
    expect(a.allowedOrigins, ['a.example.com']);
    expect(a.maxConnections, 5);
    expect(a.maxMessageSize, 2048);
    expect(a.activityTimeout, 45);
    expect(a.rateLimiting!.maxAttempts, 10);
    expect(a.rateLimiting!.decay, const Duration(seconds: 5));
    expect(a.rateLimiting!.terminate, isTrue);
    expect(a.encryptionMasterKey, hasLength(32));
    expect(b.allowedOrigins, ['*']);
    expect(b.rateLimiting, isNull);
  });

  test('toMap has no secret', () {
    final config = ReverbConfig.fromEnv(
      Env.fromMap({
        'REVERB_APPS': jsonEncode([
          {'app_id': 'a', 'key': 'key-a', 'secret': longSecret},
        ]),
      }),
    );
    final text = jsonEncode(config.toMap());
    expect(text, isNot(contains(longSecret)));
    expect(text, contains('key-a'));
    expect(config.key, 'reverb');
  });

  test('a malformed REVERB_APPS or setting is a ConfigException', () {
    for (final env in [
      {'REVERB_APPS': '[{'},
      {'REVERB_APPS': '{}'},
      {'REVERB_APPS': '[1]'},
      {
        'REVERB_APPS': jsonEncode([
          {'app_id': 'a', 'key': 'k'},
        ]),
      },
      {'REVERB_SERVER_AUTH': 'nobody'},
      {'REVERB_APPS_PROVIDER': 'redis'},
    ]) {
      expect(
        () => ReverbConfig.fromEnv(Env.fromMap(env)),
        throwsA(isA<ConfigException>()),
        reason: '$env',
      );
    }
  });

  test('settings that cannot work are a ConfigException naming them', () {
    Map<String, Object?> app(Map<String, Object?> extra) => {
      'app_id': 'a',
      'key': 'k',
      'secret': 's',
      ...extra,
    };
    for (final (entry, named) in <(Map<String, Object?>, String)>[
      (app({'max_message_size': 0}), 'max_message_size'),
      (app({'max_message_size': '-1'}), 'max_message_size'),
      (app({'activity_timeout': 0}), 'activity_timeout'),
      (app({'max_connections': -1}), 'max_connections'),
      (
        app({
          'rate_limiting': {'enabled': true, 'decay_seconds': 0},
        }),
        'decay_seconds',
      ),
      (
        app({
          'rate_limiting': {'enabled': true, 'max_attempts': '60'},
        }),
        'max_attempts',
      ),
      (
        app({'encryption_master_key': base64.encode(List.filled(16, 1))}),
        'encryption_master_key',
      ),
    ]) {
      expect(
        () => ReverbConfig.appFromMap(entry, 'REVERB_APPS[0]'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains(named),
          ),
        ),
        reason: '$entry',
      );
    }
    // What stays accepted: numbers as strings at the top level (env JSON),
    // a 32-byte key, rate limiting with its defaults.
    final ok = ReverbConfig.appFromMap(
      app({
        'max_message_size': '20000',
        'encryption_master_key': base64.encode(List.filled(32, 1)),
        'rate_limiting': {'enabled': true},
      }),
      'REVERB_APPS[0]',
    );
    expect(ok.maxMessageSize, 20000);
    expect(ok.rateLimiting?.maxAttempts, 60);
  });

  test('check: unique ids and keys, origins, short secrets', () {
    final issues = check({
      'REVERB_APPS': jsonEncode([
        {'app_id': 'a', 'key': 'k', 'secret': longSecret},
        {
          'app_id': 'a',
          'key': 'k',
          'secret': 'short',
          'allowed_origins': ['https://example.com/x'],
          'max_message_size': 50000,
        },
      ]),
    }).toList();
    String messages(ConfigIssueLevel level) =>
        issues.where((i) => i.level == level).map((i) => i.message).join('\n');
    expect(messages(ConfigIssueLevel.error), contains('app_id "a"'));
    expect(messages(ConfigIssueLevel.error), contains('key "k"'));
    expect(messages(ConfigIssueLevel.error), contains('https://example.com/x'));
    expect(messages(ConfigIssueLevel.warning), contains('32 bytes'));
    expect(messages(ConfigIssueLevel.warning), contains('max_message_size'));
    expect(issues.join(), isNot(contains(longSecret)));
  });

  test('check accepts host patterns and a valid server', () {
    expect(
      check({
        'REVERB_SERVER_PATH': '/ws',
        'REVERB_APPS': jsonEncode([
          {
            'app_id': 'a',
            'key': 'k',
            'secret': longSecret,
            'allowed_origins': ['*', '*.example.com', 'localhost:3000'],
          },
        ]),
      }),
      isEmpty,
    );
    expect(
      check({'REVERB_SERVER_PATH': 'ws', 'REVERB_SERVER_ISOLATES': '0'}),
      hasLength(2),
    );
  });

  test('doctor runs the Reverb checks (Application.configChecks)', () async {
    final app =
        Application.configure(
              basePath: Directory.systemTemp.createTempSync('reverb_dr_').path,
            )
            .withEnv({
              'APP_ENV': 'testing',
              'DB_DATABASE': ':memory:',
              'REVERB_APPS': jsonEncode([
                {'app_id': 'a', 'key': 'k', 'secret': 'twenty-characters-xx'},
              ]),
            })
            .withLogLevel(LogLevel.critical)
            .withBroadcasting()
            .withReverb()
            .create();
    await app.boot();
    addTearDown(app.shutdown);
    expect(app.configChecks, contains(ReverbConfig.check));
    final issues = ConfigValidator(extraChecks: app.configChecks)
        .validate(app.env, app.config);
    expect(
      issues.where((i) => !i.isError).map((i) => i.message),
      contains(contains('shorter than 32 bytes')),
    );
  });
}
