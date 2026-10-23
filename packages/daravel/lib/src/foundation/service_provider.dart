import 'dart:async';

import 'container.dart';

/// Registers and boots services, mirroring Laravel's two-phase providers.
///
/// All [register] methods run before any [boot] method. Both may be
/// asynchronous. Providers receive the application's [Container]; the
/// `Application`, `ConfigRepository`, `Env`, `Router` and other core services
/// are already bound when [register] is called.
abstract class ServiceProvider {
  const ServiceProvider();

  /// Bind services into the container. Do not resolve other services here.
  FutureOr<void> register(Container container) {}

  /// Called after every provider has registered; safe to resolve services.
  FutureOr<void> boot(Container container) {}
}
