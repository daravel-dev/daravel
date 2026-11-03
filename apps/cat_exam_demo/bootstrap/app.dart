import 'dart:io';

import 'package:daravel/daravel.dart';

import 'package:cat_exam_demo/lang/exam_lines.dart';

import '../routes/api.dart';
import '../routes/console.dart';
import '../routes/web.dart';
import 'jobs.dart';
import 'listeners.dart';
import 'migrations.dart';
import 'models.dart';
import 'policies.dart';
import 'seeders.dart';

/// Detects application base path when executed from repository root or package folder.
String _resolveBasePath() {
  final current = Directory.current.path;
  final candidate = Directory(
    Platform.isWindows
        ? '$current\\apps\\cat_exam_demo'
        : '$current/apps/cat_exam_demo',
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
        .withMigrations(migrations)
        .withSeeders(seeders)
        .withModels(models)
        .withJobs(jobs)
        .withSchedule(consoleRoutes)
        .withEvents(registerListeners)
        .withPolicies(registerPolicies)
        // English by default; `?lang=id` or `Accept-Language: id` switches
        // a request to Indonesian (SetLocaleMiddleware below).
        .withTranslations(examLines)
        .withRouting(
          api: apiRoutes,
          web: webRoutes,
          apiPrefix: '/api',
          health: '/up',
        )
        .withMiddleware((middleware) {
          middleware.use(const <Middleware>[
            RequestIdMiddleware(),
            SetLocaleMiddleware(supported: ['en', 'id']),
            SecurityHeadersMiddleware(),
            TrimStringsMiddleware(),
            ConvertEmptyStringsToNullMiddleware(),
          ]);
        })
        .create();
