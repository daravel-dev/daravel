// Listener registry: event → listeners (EventServiceProvider::$listen).
import 'package:daravel/daravel.dart';
// <dartisan:imports>
import 'package:daravel_starter/app/events/user_registered.dart';
import 'package:daravel_starter/app/listeners/queue_welcome_email.dart';

// </dartisan:imports>

/// Maintained by `dartisan make:*`; entries may also be added by hand.
void registerListeners(EventDispatcher events) {
  // <dartisan:entries>
  events.listen<UserRegistered>(const QueueWelcomeEmail().handle);
  // </dartisan:entries>
}
