import 'package:daravel/daravel.dart';
import 'package:daravel_starter/app/events/user_registered.dart';
import 'package:daravel_starter/app/jobs/send_welcome_email.dart';

/// Queues the welcome email when a user registers (wired in
/// `bootstrap/listeners.dart`).
final class QueueWelcomeEmail {
  const QueueWelcomeEmail();

  Future<void> handle(UserRegistered event) async {
    await Queue.dispatch(SendWelcomeEmail(event.userId));
  }
}
