import 'dart:io';

import 'package:daravel/daravel.dart';

import '../routes/api.dart';
import '../routes/web.dart';

/// Detects application base path when executed from repository root or package folder.
String _resolveBasePath() {
  final current = Directory.current.path;
  final candidate = Directory(
    Platform.isWindows
        ? '$current\\apps\\websocket_demo'
        : '$current/apps/websocket_demo',
  );
  if (candidate.existsSync()) {
    return candidate.path;
  }
  return current;
}

/// Builds the unbooted application. Safe to call once per isolate.
Application createApp({String? basePath, Map<String, String>? env}) =>
    Application.configure(basePath: basePath ?? _resolveBasePath())
        .withEnv(env ?? const <String, String>{})
        .withRouting(
          web: webRoutes,
          api: apiRoutes,
          apiPrefix: '/api',
          health: '/up',
        )
        .withMiddleware((middleware) {
          middleware.use(const <Middleware>[
            RequestIdMiddleware(),
            SecurityHeadersMiddleware(),
          ]);
        })
        .create();
