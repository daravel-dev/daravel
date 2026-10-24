import 'dart:async';

import 'exceptions.dart';

/// Builds an instance of [T] using the [Container].
typedef Factory<T extends Object> = T Function(Container container);

/// Identifies a binding: a [Type] plus an optional name for contextual bindings
/// (for example two `Disk` implementations registered as `local` and `s3`).
final class BindingKey {
  const BindingKey(this.type, [this.name]);

  final Type type;
  final String? name;

  @override
  bool operator ==(Object other) =>
      other is BindingKey && other.type == type && other.name == name;

  @override
  int get hashCode => Object.hash(type, name);

  @override
  String toString() => name == null ? '$type' : '$type(name: $name)';
}

/// Lifetime of a binding registered through a factory.
enum Lifetime {
  /// One instance per isolate, created lazily on first resolution.
  singleton,

  /// A fresh instance on every resolution.
  transient,

  /// One instance per active [Scope] (request, job, command, test).
  scoped,
}

final class _Binding {
  const _Binding(this.lifetime, this.factory);

  final Lifetime lifetime;
  final Factory<Object> factory;
}

/// The IoC container (BLUEPRINT_V2 §7.1.1, ADR-001).
///
/// Resolution order of [make]: active [Scope] → explicit instances →
/// singletons → transients. Request/job/command/test scopes are created with
/// [runScoped], which stores the scope in the current [Zone]. [current]
/// resolves the container from the zone first and falls back to the
/// per-isolate root container registered by `Application.boot()`.
final class Container {
  Container();

  static const Symbol _containerKey = #daravel.container;
  static const Symbol _scopeKey = #daravel.scope;
  static Container? _root;

  final Map<BindingKey, Object> _instances = {};
  final Map<BindingKey, _Binding> _bindings = {};
  final Map<BindingKey, BindingKey> _aliases = {};
  final Map<BindingKey, List<Object Function(Object, Container)>> _extenders =
      {};
  final Map<String, List<BindingKey>> _tags = {};
  final List<void Function(Object, Container)> _resolvingHooks = [];
  final Map<Type, void Function(Container)> _deferred = {};
  final List<BindingKey> _resolutionStack = [];

  // ---------------------------------------------------------------------------
  // Registration
  // ---------------------------------------------------------------------------

  /// Registers an already constructed [value] as a singleton instance.
  void instance<T extends Object>(T value, {String? name}) {
    final key = BindingKey(T, name);
    _bindings.remove(key);
    _instances[key] = value;
  }

  /// Registers a lazily constructed singleton (one instance per isolate).
  void singleton<T extends Object>(Factory<T> factory, {String? name}) =>
      _register<T>(Lifetime.singleton, factory, name);

  /// Registers a transient binding (a new instance on each [make]).
  void bind<T extends Object>(Factory<T> factory, {String? name}) =>
      _register<T>(Lifetime.transient, factory, name);

  /// Registers a scoped binding (one instance per active [Scope]).
  void scoped<T extends Object>(Factory<T> factory, {String? name}) =>
      _register<T>(Lifetime.scoped, factory, name);

  void _register<T extends Object>(
    Lifetime lifetime,
    Factory<T> factory,
    String? name,
  ) {
    final key = BindingKey(T, name);
    _instances.remove(key);
    _bindings[key] = _Binding(lifetime, factory);
  }

  /// Decorates the binding for [T]: [decorator] receives the resolved
  /// instance and returns the (wrapped) instance to use instead. Applies
  /// immediately to already-resolved instances.
  void extend<T extends Object>(
    T Function(T existing, Container container) decorator, {
    String? name,
  }) {
    final key = _canonical(BindingKey(T, name));
    final existing = _instances[key];
    if (existing != null) {
      _instances[key] = decorator(existing as T, this);
      return;
    }
    _extenders
        .putIfAbsent(key, () => [])
        .add((instance, container) => decorator(instance as T, container));
  }

  /// Makes `make<TAlias>()` resolve the binding registered for [TTarget]
  /// (for example an interface to its default implementation).
  void alias<TAlias extends Object, TTarget extends Object>({String? name}) {
    _aliases[BindingKey(TAlias, name)] = BindingKey(TTarget, name);
  }

  /// Adds the binding for [T] to [tag] so it can be resolved via [tagged].
  void tag<T extends Object>(String tag, {String? name}) {
    _tags.putIfAbsent(tag, () => []).add(BindingKey(T, name));
  }

  /// Resolves every binding registered under [tag], in registration order.
  List<Object> tagged(String tag) => [
    for (final key in _tags[tag] ?? const <BindingKey>[]) _makeByKey(key),
  ];

  /// Registers a callback invoked after any instance of [T] is constructed
  /// by the container (not for instances registered via [instance]).
  void resolving<T extends Object>(
    void Function(T instance, Container container) hook,
  ) {
    _resolvingHooks.add((instance, container) {
      if (instance is T) {
        hook(instance, container);
      }
    });
  }

  /// Registers [register] to run lazily the first time any of [provides] is
  /// resolved (deferred service providers).
  void deferred(
    List<Type> provides,
    void Function(Container container) register,
  ) {
    for (final type in provides) {
      _deferred[type] = register;
    }
  }

  /// Whether a binding or instance exists for [T] (and [name]).
  bool bound<T extends Object>({String? name}) {
    final key = _canonical(BindingKey(T, name));
    return _instances.containsKey(key) ||
        _bindings.containsKey(key) ||
        _deferred.containsKey(key.type);
  }

  /// Removes the binding and any cached instance for [T] (and [name]).
  void forget<T extends Object>({String? name}) {
    final key = BindingKey(T, name);
    _instances.remove(key);
    _bindings.remove(key);
    _extenders.remove(key);
    _aliases.remove(key);
  }

  BindingKey _canonical(BindingKey key) {
    var current = key;
    var hops = 0;
    while (true) {
      final target = _aliases[current];
      if (target == null) {
        return current;
      }
      if (++hops > 32) {
        throw StateError('Alias cycle detected starting at [$key].');
      }
      current = target;
    }
  }

  // ---------------------------------------------------------------------------
  // Resolution
  // ---------------------------------------------------------------------------

  /// Resolves [T]; throws [BindingResolutionException] when unknown.
  T make<T extends Object>({String? name}) =>
      _makeByKey(BindingKey(T, name)) as T;

  Object _makeByKey(BindingKey requested) {
    final key = _canonical(requested);
    final scope = currentScope;

    if (scope != null) {
      final scopedInstance = scope._get(key);
      if (scopedInstance != null) {
        return scopedInstance;
      }
    }

    final existing = _instances[key];
    if (existing != null) {
      return existing;
    }

    final binding = _bindings[key];
    if (binding == null) {
      final register = _deferred[key.type];
      if (register != null) {
        _deferred.removeWhere((_, callback) => identical(callback, register));
        register(this);
        // Re-resolve: the provider may have registered an alias for the key.
        return _makeByKey(requested);
      }
    }
    if (binding == null) {
      throw BindingResolutionException(key, scope: scope?.name);
    }

    switch (binding.lifetime) {
      case .singleton:
        final created = _build(key, binding);
        _instances[key] = created;
        return created;
      case .transient:
        return _build(key, binding);
      case .scoped:
        if (scope == null) {
          throw ScopeRequiredException(key);
        }
        final created = _build(key, binding);
        scope._put(key, created);
        return created;
    }
  }

  /// Like [make] but returns `null` instead of throwing when [T] is unknown.
  T? tryMake<T extends Object>({String? name}) {
    try {
      return make<T>(name: name);
    } on BindingResolutionException {
      return null;
    }
  }

  /// Returns the cached singleton/instance for [T] without constructing it.
  T? resolved<T extends Object>({String? name}) =>
      _instances[BindingKey(T, name)] as T?;

  Object _build(BindingKey key, _Binding binding) {
    if (_resolutionStack.contains(key)) {
      throw CircularDependencyException([..._resolutionStack, key]);
    }
    _resolutionStack.add(key);
    try {
      var instance = binding.factory(this);
      for (final extender
          in _extenders[key] ?? const <Object Function(Object, Container)>[]) {
        instance = extender(instance, this);
      }
      for (final hook in _resolvingHooks) {
        hook(instance, this);
      }
      return instance;
    } finally {
      _resolutionStack.removeLast();
    }
  }

  // ---------------------------------------------------------------------------
  // Scopes & zones
  // ---------------------------------------------------------------------------

  /// The [Scope] of the current zone, if any.
  Scope? get currentScope => Zone.current[_scopeKey] as Scope?;

  /// Runs [body] inside a new [Scope] named [scopeName].
  ///
  /// The scope and this container are stored in a child [Zone] so that
  /// facades and [Container.current] resolve them from anywhere inside
  /// [body], including across `await` boundaries. The scope is disposed when
  /// [body] completes. Uncaught asynchronous errors (fire-and-forget futures)
  /// are routed to [onUncaughtError] instead of terminating the isolate.
  Future<R> runScoped<R>(
    String scopeName,
    FutureOr<R> Function(Scope scope) body, {
    void Function(Object error, StackTrace stackTrace)? onUncaughtError,
  }) {
    final scope = Scope._(scopeName, this);
    final completer = Completer<R>();

    void reportUncaught(Object error, StackTrace stackTrace) {
      if (onUncaughtError != null) {
        onUncaughtError(error, stackTrace);
      } else {
        Zone.root.print(
          '[daravel] Uncaught error in scope "$scopeName": $error\n$stackTrace',
        );
      }
    }

    unawaited(
      runZonedGuarded<Future<void>>(
        () async {
          late final R result;
          Object? failure;
          StackTrace? failureTrace;
          try {
            result = await body(scope);
          } catch (error, stackTrace) {
            failure = error;
            failureTrace = stackTrace;
          }
          // Dispose before releasing the caller so that per-scope resources are
          // gone by the time `await runScoped(...)` resumes.
          try {
            await scope.dispose();
          } catch (error, stackTrace) {
            reportUncaught(error, stackTrace);
          }
          if (completer.isCompleted) {
            return;
          }
          if (failure != null) {
            completer.completeError(failure, failureTrace);
          } else {
            completer.complete(result);
          }
        },
        (error, stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          } else {
            reportUncaught(error, stackTrace);
          }
        },
        zoneValues: <Object?, Object?>{_containerKey: this, _scopeKey: scope},
      ),
    );

    return completer.future;
  }

  /// The container of the current zone, falling back to the isolate root.
  static Container get current {
    final zoned = Zone.current[_containerKey] as Container?;
    if (zoned != null) {
      return zoned;
    }
    final root = _root;
    if (root == null) {
      throw StateError(
        'No Daravel container is active. Boot an Application (or call '
        'Container.setRoot) before using facades.',
      );
    }
    return root;
  }

  /// The per-isolate root container, if one has been registered.
  static Container? get rootOrNull => _root;

  /// Registers (or clears, with `null`) the per-isolate root container.
  static void setRoot(Container? container) => _root = container;
}

/// Per-request/job/command/test storage created by [Container.runScoped].
final class Scope {
  Scope._(this.name, this.container);

  /// Scope name, e.g. `request`, `job`, `command`, `test`.
  final String name;

  /// The owning container.
  final Container container;

  final Map<BindingKey, Object> _instances = {};
  final List<FutureOr<void> Function()> _disposers = [];
  bool _disposed = false;

  /// Whether [dispose] has already run.
  bool get disposed => _disposed;

  Object? _get(BindingKey key) => _instances[key];

  void _put(BindingKey key, Object value) {
    _ensureActive();
    _instances[key] = value;
  }

  /// Returns the scoped instance of [T], if one was created or [put].
  T? get<T extends Object>({String? name}) =>
      _instances[BindingKey(T, name)] as T?;

  /// Stores [instance] as the scoped instance of [T].
  void put<T extends Object>(T instance, {String? name}) =>
      _put(BindingKey(T, name), instance);

  /// Registers a callback executed (LIFO) when the scope is disposed.
  void onDispose(FutureOr<void> Function() callback) {
    _ensureActive();
    _disposers.add(callback);
  }

  /// Runs all dispose callbacks in reverse order. A failing callback does not
  /// prevent the others from running; failures are collected into a
  /// [ScopeDisposeException].
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final errors = <Object>[];
    for (final disposer in _disposers.reversed) {
      try {
        await disposer();
      } catch (error) {
        errors.add(error);
      }
    }
    _disposers.clear();
    _instances.clear();
    if (errors.isNotEmpty) {
      throw ScopeDisposeException(name, errors);
    }
  }

  void _ensureActive() {
    if (_disposed) {
      throw StateError('Scope "$name" is already disposed.');
    }
  }
}
