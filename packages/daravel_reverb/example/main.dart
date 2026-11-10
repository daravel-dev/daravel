import 'dart:convert';

import 'package:daravel/daravel.dart';
import 'package:daravel_reverb/daravel_reverb.dart';

/// Reads the applications of a `REVERB_APPS` value and prints what the
/// config check says about them.
void main() {
  final env = Env.fromMap({
    'REVERB_APPS': jsonEncode([
      {'app_id': '1', 'key': 'tenant-a', 'secret': 'a' * 32},
      {
        'app_id': '2',
        'key': 'tenant-b',
        'secret': 'short',
        'allowed_origins': ['b.example.com'],
      },
    ]),
  });
  final config = ConfigRepository()
    ..register<ReverbConfig>(ReverbConfig.fromEnv(env))
    ..register<BroadcastConfig>(BroadcastConfig.fromEnv(env));
  for (final app in config.section<ReverbConfig>().apps) {
    print('${app.id}: ${app.toPublicMap()}');
  }
  for (final issue in ReverbConfig.check(env, config)) {
    print('${issue.level.name}: ${issue.message}');
  }
}
