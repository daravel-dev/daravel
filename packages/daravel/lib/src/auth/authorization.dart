import 'dart:async';

import '../foundation/container.dart';
import '../http/middleware.dart';
import '../http/request.dart';
import '../http/response.dart';
import 'contracts.dart';

/// Ability callback: returns `bool`, [AuthResponse] or `null` (= no opinion
/// in `before`/`after` hooks, deny in abilities).
typedef GateCallback = FutureOr<Object?> Function(
  Authenticatable? user,
  List<Object?> args,
);

/// `before` hook: a non-null result short-circuits the check.
typedef GateBeforeHook = FutureOr<Object?> Function(
  Authenticatable? user,
  String ability,
  List<Object?> args,
);

/// `after` hook: may override the result by returning non-null.
typedef GateAfterHook = FutureOr<Object?> Function(
  Authenticatable? user,
  String ability,
  AuthResponse result,
  List<Object?> args,
);

/// Result of an authorization check with an optional message and code.
final class AuthResponse {
  const AuthResponse.allow([this.message]) : allowed = true, code = null;

  const AuthResponse.deny([
    this.message = 'This action is unauthorized.',
    this.code,
  ]) : allowed = false;

  final bool allowed;
  final String? message;
  final Object? code;

  bool get denied => !allowed;

  /// Throws [AuthorizationException] when denied.
  void authorize() {
    if (!allowed) {
      throw AuthorizationException(
        message ?? 'This action is unauthorized.',
        code,
      );
    }
  }

  /// Coerces a callback result into a response.
  static AuthResponse from(Object? result) => switch (result) {
    AuthResponse() => result,
    true => const AuthResponse.allow(),
    _ => const AuthResponse.deny(),
  };
}

/// Groups authorization logic for one model type (Laravel `Policy`).
///
/// Methods default to deny; override the ones you need and add custom
/// abilities through [extra].
abstract class Policy<T extends Object> {
  const Policy();

  /// Runs before every ability; return `true`/`false`/[AuthResponse] to
  /// short-circuit or `null` to continue.
  FutureOr<Object?> before(Authenticatable? user, String ability) => null;

  FutureOr<Object?> viewAny(Authenticatable? user) => false;
  FutureOr<Object?> view(Authenticatable? user, T model) => false;
  FutureOr<Object?> create(Authenticatable? user) => false;
  FutureOr<Object?> update(Authenticatable? user, T model) => false;
  FutureOr<Object?> delete(Authenticatable? user, T model) => false;
  FutureOr<Object?> restore(Authenticatable? user, T model) => false;
  FutureOr<Object?> forceDelete(Authenticatable? user, T model) => false;

  /// Non-standard abilities keyed by name.
  Map<String, GateCallback> get extra => const <String, GateCallback>{};

  /// Dispatches [ability] to the matching method. [args] starts with the
  /// model (or is empty for `viewAny`/`create`).
  FutureOr<Object?> dispatch(
    Authenticatable? user,
    String ability,
    List<Object?> args,
  ) {
    final model = args.isEmpty ? null : args.first;
    switch (ability) {
      case 'viewAny':
        return viewAny(user);
      case 'create':
        return create(user);
      case 'view' || 'update' || 'delete' || 'restore' || 'forceDelete':
        if (model is! T) {
          return false;
        }
        return switch (ability) {
          'view' => view(user, model),
          'update' => update(user, model),
          'delete' => delete(user, model),
          'restore' => restore(user, model),
          _ => forceDelete(user, model),
        };
      default:
        final callback = extra[ability];
        return callback == null ? false : callback(user, args);
    }
  }

  /// Whether the policy handles [ability].
  bool handles(String ability) =>
      const <String>{
        'viewAny',
        'view',
        'create',
        'update',
        'delete',
        'restore',
        'forceDelete',
      }.contains(ability) ||
      extra.containsKey(ability);
}

final class _PolicyEntry {
  const _PolicyEntry(this.type, this.matches, this.policy);

  final Type type;
  final bool Function(Object instance) matches;
  final Policy<Object> policy;
}

/// Ability registry and checker (Laravel `Gate`). One instance per
/// application; [forUser] yields a view bound to a specific user.
final class AuthorizationGate {
  AuthorizationGate({this._userResolver})
    : _boundUser = null,
      _isBound = false,
      _abilities = <String, GateCallback>{},
      _policies = <_PolicyEntry>[],
      _before = <GateBeforeHook>[],
      _after = <GateAfterHook>[];

  AuthorizationGate._bound(AuthorizationGate parent, this._boundUser)
    : _userResolver = null,
      _abilities = parent._abilities,
      _policies = parent._policies,
      _before = parent._before,
      _after = parent._after,
      _isBound = true;

  final Future<Authenticatable?> Function()? _userResolver;
  final Authenticatable? _boundUser;
  final bool _isBound;
  final Map<String, GateCallback> _abilities;
  final List<_PolicyEntry> _policies;
  final List<GateBeforeHook> _before;
  final List<GateAfterHook> _after;

  /// Registers an ability.
  void define(String ability, GateCallback callback) =>
      _abilities[ability] = callback;

  /// Registers [policy] for instances (and the [Type]) of `T`. The first
  /// policy whose type matches an instance (`is` check) wins, so register
  /// subclasses before their parents.
  void policy<T extends Object>(Policy<T> policy) =>
      _policies.add(_PolicyEntry(T, (o) => o is T, policy));

  void before(GateBeforeHook hook) => _before.add(hook);

  void after(GateAfterHook hook) => _after.add(hook);

  bool has(String ability) => _abilities.containsKey(ability);

  /// A gate that checks abilities for [user] instead of the current user.
  AuthorizationGate forUser(Authenticatable? user) =>
      AuthorizationGate._bound(this, user);

  Future<bool> allows(String ability, [List<Object?> args = const []]) async =>
      (await inspect(ability, args)).allowed;

  Future<bool> denies(String ability, [List<Object?> args = const []]) async =>
      !(await allows(ability, args));

  /// Every ability allowed.
  Future<bool> check(
    Iterable<String> abilities, [
    List<Object?> args = const [],
  ]) async {
    for (final ability in abilities) {
      if (!await allows(ability, args)) {
        return false;
      }
    }
    return true;
  }

  /// At least one ability allowed.
  Future<bool> any(
    Iterable<String> abilities, [
    List<Object?> args = const [],
  ]) async {
    for (final ability in abilities) {
      if (await allows(ability, args)) {
        return true;
      }
    }
    return false;
  }

  Future<bool> none(
    Iterable<String> abilities, [
    List<Object?> args = const [],
  ]) async => !(await any(abilities, args));

  /// Throws [AuthorizationException] (403) when denied.
  Future<AuthResponse> authorize(
    String ability, [
    List<Object?> args = const [],
  ]) async {
    final response = await inspect(ability, args);
    response.authorize();
    return response;
  }

  /// Full result with message/code.
  Future<AuthResponse> inspect(
    String ability, [
    List<Object?> args = const [],
  ]) async {
    final user = await _resolveUser();
    final result = AuthResponse.from(await _raw(user, ability, args));
    var response = result;
    for (final hook in _after) {
      final override = await hook(user, ability, response, args);
      if (override != null) {
        response = AuthResponse.from(override);
      }
    }
    return response;
  }

  /// Finds the policy registered for [target] (an instance or a [Type]).
  Policy<Object>? policyFor(Object? target) {
    if (target == null) {
      return null;
    }
    if (target is Type) {
      for (final entry in _policies) {
        if (entry.type == target) {
          return entry.policy;
        }
      }
      return null;
    }
    for (final entry in _policies) {
      if (entry.type == target.runtimeType) {
        return entry.policy;
      }
    }
    for (final entry in _policies) {
      if (entry.matches(target)) {
        return entry.policy;
      }
    }
    return null;
  }

  Future<Object?> _raw(
    Authenticatable? user,
    String ability,
    List<Object?> args,
  ) async {
    for (final hook in _before) {
      final result = await hook(user, ability, args);
      if (result != null) {
        return result;
      }
    }
    final policy = policyFor(args.isEmpty ? null : args.first);
    if (policy != null && policy.handles(ability)) {
      final before = await policy.before(user, ability);
      if (before != null) {
        return before;
      }
      final policyArgs = args.first is Type ? args.sublist(1) : args;
      return policy.dispatch(user, ability, policyArgs);
    }
    final callback = _abilities[ability];
    if (callback == null) {
      return false;
    }
    return callback(user, args);
  }

  Future<Authenticatable?> _resolveUser() async {
    if (_isBound) {
      return _boundUser;
    }
    final resolver = _userResolver;
    return resolver == null ? null : await resolver();
  }
}

/// Middleware `can:ability,param1,param2` — route parameters are passed as
/// their bound models (see `Router.bind`) or raw strings.
final class AuthorizeMiddleware implements Middleware {
  const AuthorizeMiddleware(this.ability, [this.params = const <String>[]]);

  factory AuthorizeMiddleware.fromParams(List<String> params) {
    if (params.isEmpty) {
      throw ArgumentError(
        'can: middleware requires an ability, e.g. can:update,post',
      );
    }
    return AuthorizeMiddleware(params.first, params.sublist(1));
  }

  final String ability;
  final List<String> params;

  @override
  Future<Response> handle(Request request, Next next) async {
    final gate = Container.current.make<AuthorizationGate>();
    final args = <Object?>[
      for (final param in params) _argument(request, param),
    ];
    await gate.authorize(ability, args);
    return next(request);
  }

  static Object? _argument(Request request, String param) {
    try {
      return request.binding<Object?>(param);
    } on StateError {
      return request.routeParams[param] ?? param;
    }
  }
}
