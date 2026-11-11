import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_reverb/daravel_reverb.dart';
import 'package:reverb_demo/demo.dart';

import '../routes/channels.dart';
import '../routes/web.dart';

/// Detects the application's base path when run from the repository root
/// or the package folder.
String _resolveBasePath() {
  final current = Directory.current.path;
  final sep = Platform.pathSeparator;
  final candidate = Directory('$current${sep}apps${sep}reverb_demo');
  return candidate.existsSync() ? candidate.path : current;
}

/// Builds the unbooted application: the HTTP server (`bin/server.dart`)
/// and, with only its broadcasting, `reverb:start` in each worker isolate.
Application createApp({String? basePath, Map<String, String>? env}) =>
    Application.configure(basePath: basePath ?? _resolveBasePath())
        .withEnv(env ?? const <String, String>{})
        .withAuth((auth) {
          auth.register(
            'token',
            ClosureGuard<DemoUser>(
              name: 'token',
              resolver: (request) => demoUser(request.bearerToken()),
            ),
          );
        })
        .withPolicies((gate) {
          gate.define(
            'viewReverb',
            (user, _) => user is DemoUser && user.isAdmin,
          );
        })
        .withRouting(web: webRoutes, health: '/up')
        .withBroadcasting(channels: registerChannels)
        .withReverb(middleware: ['auth', 'can:viewReverb'])
        .create();
