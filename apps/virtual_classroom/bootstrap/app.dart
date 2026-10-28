import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_activitylog/daravel_activitylog.dart';
import 'package:daravel_google/daravel_google.dart';
import 'package:daravel_livekit/daravel_livekit.dart';
import 'package:daravel_permission/daravel_permission.dart';
import 'package:virtual_classroom/app/models/meeting.dart';
import 'package:virtual_classroom/app/models/user.dart';
import 'package:virtual_classroom/app/policies/meeting_policy.dart';

import '../routes/api.dart';
import 'jobs.dart';
import 'migrations.dart';
import 'models.dart';
import 'seeders.dart';

/// Builds the (unbooted) application. [env] overrides `.env` and the OS
/// environment, which is how tests pick their database and fakes.
Application createApp({String? basePath, Map<String, String>? env}) =>
    Application.configure(basePath: basePath ?? Directory.current.path)
        .withEnv(env ?? const <String, String>{})
        .withLivekit()
        .withGoogle()
        .withPermissions()
        .withActivityLog()
        .withMigrations(migrations)
        .withSeeders(seeders)
        .withModels(models)
        .withJobs(jobs)
        .withPolicies((gate) => gate.policy<Meeting>(const MeetingPolicy()))
        .withRouting(api: apiRoutes, apiPrefix: '/api', health: '/up')
        .withAuth((auth) {
          auth.token<User>('token', ModelUserProvider<User>(User.definition));
        })
        .withRateLimits((limiter) {
          // Ten tries a minute per user and meeting.
          limiter.define(
            'join',
            (request) async => Limit.perMinute(10).by(
              '${(await request.user<User>())?.id}|'
              '${request.routeParams['meeting']}',
            ),
          );
        })
        .create();
