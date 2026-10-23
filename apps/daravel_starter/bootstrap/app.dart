import 'dart:io';

import 'package:daravel/daravel.dart';

import '../routes/api.dart';
import '../routes/web.dart';
import 'migrations.dart';
import 'seeders.dart';

/// Builds the (unbooted) application. Pure: safe to call once per isolate.
///
/// [env] overrides take precedence over `.env` and the OS environment, which
/// is how tests select an in-memory database.
Application createApp({String? basePath, Map<String, String>? env}) =>
    Application.configure(basePath: basePath ?? Directory.current.path)
        .withEnv(env ?? const <String, String>{})
        .withMigrations(migrations)
        .withSeeders(seeders)
        .withRouting(
          api: apiRoutes,
          web: webRoutes,
          apiPrefix: '/api',
          health: '/up',
        )
        .withMiddleware((middleware) {
          middleware.use(const <Middleware>[
            // Only honour X-Forwarded-* from these proxies (none by default).
            // TrustProxiesMiddleware(proxies: ['10.0.0.0/8']),
            RequestIdMiddleware(),
            SecurityHeadersMiddleware(),
            BodyLimitsMiddleware(),
            TrimStringsMiddleware(),
            ConvertEmptyStringsToNullMiddleware(),
          ]);
          middleware.group('api', const <Object>[]);
        })
        .withExceptions((exceptions) {
          // Custom renderers/reporters go here, e.g.
          // exceptions.render<MyException>((e, req) => Response.json({...}));
        })
        .create();
