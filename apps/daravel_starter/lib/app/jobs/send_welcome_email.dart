import 'package:daravel/daravel.dart';
import 'package:daravel_starter/app/models/user.dart';

/// Example queued job: "sends" a welcome email to a freshly registered user.
///
/// Models travel as keys ([ModelRef]) and are reloaded when the job runs, so
/// the payload stays small and never goes stale.
final class SendWelcomeEmail extends Job {
  const SendWelcomeEmail(this.userId);

  /// Stable registry key (see `bootstrap/jobs.dart`).
  static const String name = 'send-welcome-email';

  factory SendWelcomeEmail.fromJson(Map<String, Object?> json) =>
      SendWelcomeEmail(json['user_id']!);

  final Object userId;

  @override
  String get jobName => name;

  @override
  int get tries => 3;

  @override
  List<Duration> get backoff => const [
    Duration(seconds: 10),
    Duration(seconds: 60),
  ];

  @override
  Map<String, Object?> toJson() => <String, Object?>{'user_id': userId};

  @override
  Future<void> handle(JobContext ctx) async {
    final user = await ModelRef<User>(() => User.definition, userId).resolve();
    // Mail arrives in a later slice; record the "send" so tests can observe it.
    await Cache.increment('welcome_emails');
    Log.info('Welcome email queued for ${user.email}', {
      'job_id': ctx.id,
      'attempt': ctx.attempt,
    });
  }
}
