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

/// A provider whose bindings are registered lazily, the first time one of
/// the types in [provides] is resolved from the container (Laravel's
/// `DeferrableProvider`). Registration must be synchronous because
/// `Container.make` is synchronous; [boot] is not invoked for deferred
/// providers.
abstract class DeferredServiceProvider extends ServiceProvider {
  const DeferredServiceProvider();

  /// The types this provider binds.
  List<Type> get provides;

  /// Synchronously binds the services listed in [provides].
  void registerDeferred(Container container);

  @override
  void register(Container container) =>
      container.deferred(provides, registerDeferred);
}
