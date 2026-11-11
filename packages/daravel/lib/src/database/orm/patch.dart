/// The value of [Patch.absent].
final class _Absent {
  const _Absent();

  @override
  String toString() => 'Patch.absent';
}

/// A partial-update value for a nullable column: "leave it" ([Patch.absent],
/// the default) or "set it", `null` included ([Patch.new]). A `T?`
/// parameter cannot tell "not given" from "set to null"; this can, at no
/// cost (an extension type over the value).
///
/// ```dart
/// await user.updateWith(emailVerifiedAt: const Patch(null)); // SET ... = NULL
/// await user.updateWith(name: 'Ana'); // email_verified_at untouched
/// ```
extension type const Patch<T>._(Object? _raw) {
  /// Sets the column to [value], which may be null.
  const Patch(T value) : this._(value);

  /// Leaves the column as it is.
  const Patch.absent() : this._(const _Absent());

  /// Whether a value was given (null included).
  bool get isPresent => _raw is! _Absent;

  /// The value given; only meaningful when [isPresent].
  T get value => _raw as T;
}
