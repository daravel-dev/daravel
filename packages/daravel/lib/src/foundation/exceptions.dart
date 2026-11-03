import 'container.dart';

/// Base class for every exception raised by the framework itself.
abstract class DaravelException implements Exception {
  /// An error with [message].
  const DaravelException(this.message);

  /// Human readable description of the failure.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when [Container.make] cannot find a binding for the requested type.
final class BindingResolutionException extends DaravelException {
  /// Nothing is bound for [key] (in [scope], when given).
  BindingResolutionException(this.key, {this.scope})
    : super(
        'No binding registered for [$key]'
        '${scope == null ? '' : ' (active scope: $scope)'}.',
      );

  /// The binding asked for.
  final BindingKey key;

  /// The scope it was asked in.
  final String? scope;
}

/// Thrown when a `scoped` binding is resolved outside of an active [Scope].
final class ScopeRequiredException extends DaravelException {
  /// [key] is scoped and was asked for outside its scope.
  ScopeRequiredException(this.key)
    : super(
        'Binding [$key] is scoped and can only be resolved inside '
        'Container.runScoped (request, job, command or test scope).',
      );

  /// The binding asked for.
  final BindingKey key;
}

/// Thrown when two factories depend on each other, directly or indirectly.
final class CircularDependencyException extends DaravelException {
  /// Resolving [path] came back to where it started.
  CircularDependencyException(this.path)
    : super('Circular dependency detected: ${path.join(' -> ')}');

  /// The bindings resolved, in order, ending with the repeated one.
  final List<BindingKey> path;
}

/// Raised by [Scope.dispose] when one or more dispose callbacks failed.
final class ScopeDisposeException extends DaravelException {
  /// Disposing the scope [scopeName] threw [errors].
  ScopeDisposeException(this.scopeName, this.errors)
    : super(
        '${errors.length} dispose callback(s) of scope "$scopeName" failed: '
        '${errors.join('; ')}',
      );

  /// The scope disposed.
  final String scopeName;

  /// The errors thrown.
  final List<Object> errors;
}

/// Raised for malformed `.env` files or missing/invalid environment values.
final class EnvException extends DaravelException {
  /// `.env` cannot be read or a value has the wrong type.
  const EnvException(super.message);
}

/// Raised for missing configuration keys/sections or type mismatches.
final class ConfigException extends DaravelException {
  /// The configuration is invalid.
  const ConfigException(super.message);
}
