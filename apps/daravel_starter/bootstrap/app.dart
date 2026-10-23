import 'dart:io';

import 'package:daravel/daravel.dart';

import '../database/migrations/m_2026_10_23_000001_create_users_table.dart';
import '../routes/api.dart';

/// Builds the (unbooted) application. Pure: safe to call once per isolate.
///
/// [env] overrides take precedence over `.env` and the OS environment, which
/// is how tests select an in-memory database.
Application createApp({String? basePath, Map<String, String>? env}) =>
    Application.configure(basePath: basePath ?? Directory.current.path)
        .withEnv(env ?? const <String, String>{})
        .withMigrations(const <Migration>[CreateUsersTable()])
        .withRouting(api: apiRoutes, apiPrefix: '/api', health: '/up')
        .withMiddleware((middleware) {
          middleware.use(const <Middleware>[RequestIdMiddleware()]);
        })
        .withExceptions((exceptions) {
          // Custom renderers/reporters go here, e.g.
          // exceptions.render<MyException>((e, req) => Response.json({...}));
        })
        .create();
