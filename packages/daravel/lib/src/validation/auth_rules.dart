import 'dart:async';

import 'rule.dart';

/// Checks the password of the signed-in user for `current_password`. The
/// validation module does not know the auth module: the application binds
/// one in the container (`Application` does, from `AuthManager` and
/// `HashManager`).
abstract interface class CurrentPasswordVerifier {
  /// Whether [password] is the password of the user signed in on [guard]
  /// (the default guard when null); false for a guest.
  Future<bool> verify(String password, {String? guard});
}

/// Asks the gate for `Rule::can`. The application binds one in the
/// container (`Application` does, from `AuthorizationGate`).
abstract interface class AbilityChecker {
  /// Whether the current user may perform [ability] with [arguments].
  Future<bool> allows(String ability, List<Object?> arguments);
}

T _service<T extends Object>(ValidationContext context, String rule) {
  final found = context.container?.tryMake<T>();
  if (found == null) {
    throw StateError(
      '$rule needs a $T in the container: validate inside an Application '
      '(a request, a job, TestClient, app.run) or bind one '
      '(container.instance<$T>(...)).',
    );
  }
  return found;
}

/// `current_password` and `current_password:guard`: see
/// [Rules.currentPassword].
final class CurrentPasswordRule extends Rule {
  /// The rule; use [Rules.currentPassword].
  const CurrentPasswordRule({this.guard});

  /// The guard whose user is checked (the default guard when null).
  final String? guard;

  @override
  String get name => 'current_password';

  @override
  Map<String, Object?> get parameters => {'guard': ?guard};

  @override
  Future<String?> passes(ValidationContext context) async {
    final verifier = _service<CurrentPasswordVerifier>(context, name);
    final value = context.value;
    if (value is! String) {
      return name;
    }
    return await verifier.verify(value, guard: guard) ? null : name;
  }
}

/// `Rule::can`: see [Rules.can].
final class CanRule extends Rule {
  /// The rule; use [Rules.can].
  const CanRule(this.ability, [this.arguments = const []]);

  /// The ability asked.
  final String ability;

  /// The arguments before the value (the model first).
  final List<Object?> arguments;

  @override
  String get name => 'can';

  @override
  Future<String?> passes(ValidationContext context) async {
    final checker = _service<AbilityChecker>(context, name);
    // As Laravel's Rule\Can: array_filter([$model, ...$arguments, $value])
    // drops every value PHP calls empty.
    final args = [
      for (final arg in [...arguments, context.value])
        if (!_phpEmpty(arg)) arg,
    ];
    return await checker.allows(ability, args) ? null : name;
  }

  /// PHP's falsy values, which `array_filter` drops.
  static bool _phpEmpty(Object? value) => switch (value) {
    null || false || 0 || 0.0 || '' || '0' => true,
    List<Object?>(isEmpty: true) ||
    Map<Object?, Object?>(isEmpty: true) => true,
    _ => false,
  };
}
