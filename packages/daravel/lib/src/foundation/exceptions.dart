import 'container.dart';

/// Base class for every exception raised by the framework itself.
abstract class DaravelException implements Exception {
  const DaravelException(this.message);

  /// Human readable description of the failure.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when [Container.make] cannot find a binding for the requested type.
final class BindingResolutionException extends DaravelException {
  BindingResolutionException(this.key, {this.scope})
    : super(
        'No binding registered for [$key]'
        '${scope == null ? '' : ' (active scope: $scope)'}.',
      );

  final BindingKey key;
  final String? scope;
}

/// Thrown when a `scoped` binding is resolved outside of an active [Scope].
final class ScopeRequiredException extends DaravelException {
  ScopeRequiredException(this.key)
    : super(
        'Binding [$key] is scoped and can only be resolved inside '
        'Container.runScoped (request, job, command or test scope).',
      );

  final BindingKey key;
}

/// Thrown when two factories depend on each other, directly or indirectly.
final class CircularDependencyException extends DaravelException {
  CircularDependencyException(this.path)
    : super('Circular dependency detected: ${path.join(' -> ')}');

  final List<BindingKey> path;
}

/// Raised by [Scope.dispose] when one or more dispose callbacks failed.
final class ScopeDisposeException extends DaravelException {
  ScopeDisposeException(this.scopeName, this.errors)
    : super(
        '${errors.length} dispose callback(s) of scope "$scopeName" failed: '
        '${errors.join('; ')}',
      );

  final String scopeName;
  final List<Object> errors;
}

/// Raised for malformed `.env` files or missing/invalid environment values.
final class EnvException extends DaravelException {
  const EnvException(super.message);
}

/// Raised for missing configuration keys/sections or type mismatches.
final class ConfigException extends DaravelException {
  const ConfigException(super.message);
}
