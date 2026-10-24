import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:daravel_starter/app/models/user.dart';

import '../routes/api.dart';
import '../routes/console.dart';
import '../routes/web.dart';
import 'jobs.dart';
import 'listeners.dart';
import 'migrations.dart';
import 'policies.dart';
import 'seeders.dart';

/// Builds the (unbooted) application. Pure: safe to call once per isolate.
///
/// [env] overrides take precedence over `.env` and the OS environment, which
/// is how tests select an in-memory database.
Application createApp({String? basePath, Map<String, String>? env}) =>
    Application.configure(basePath: basePath ?? Directory.current.path)
        .withEnv(env ?? const <String, String>{})
        // DB_CONNECTION=mysql or mariadb (sqlite and pgsql are built in).
        .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
        .withDatabaseDriver('mariadb', MySqlDriver.fromConfig)
        .withMigrations(migrations)
        .withSeeders(seeders)
        .withJobs(jobs)
        .withSchedule(consoleRoutes)
        .withEvents(registerListeners)
        .withPolicies(registerPolicies)
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
        .withAuth((auth) {
          // Sanctum-style bearer tokens stored in `personal_access_tokens`.
          auth.token<User>('token', ModelUserProvider<User>(User.definition));
          // Stateless JWTs signed with JWT_SECRET (or APP_KEY):
          // auth.jwt<User>('jwt', ModelUserProvider<User>(User.definition));
        })
        .withRateLimits((limiter) {
          limiter.define('login', (request) async {
            final email = (await request.all())['email'];
            return Limit.perMinute(5).by('$email|${request.ip}');
          });
          limiter.define(
            'register',
            (request) => Limit.perMinute(5).by(request.ip),
          );
        })
        .withExceptions((exceptions) {
          // Custom renderers/reporters go here, e.g.
          // exceptions.render<MyException>((e, req) => Response.json({...}));
        })
        .create();
