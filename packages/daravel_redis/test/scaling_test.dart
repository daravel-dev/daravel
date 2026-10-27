@Tags(['integration'])
library;

import 'dart:io';
import 'dart:math';

import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

// The framework's two-server broadcasting suite, through Redis Pub/Sub
// instead of the database. Not published (.pubignore): the import reaches
// into the workspace.
import '../../daravel/test/broadcasting/scaling_test.dart' show scalingTests;

void main() {
  final url = Platform.environment['DARAVEL_TEST_REDIS'];
  if (url == null || url.isEmpty) {
    test(
      'Redis scaling (skipped: DARAVEL_TEST_REDIS not set)',
      () {},
      skip: true,
    );
    return;
  }
  scalingTests(
    configure: (builder) => builder.withRedis(),
    env: {
      'REVERB_SCALING_DRIVER': 'redis',
      'REDIS_URL': url,
      'REDIS_PREFIX': 'scaling_${Random().nextInt(1 << 32)}_',
    },
  );
}
