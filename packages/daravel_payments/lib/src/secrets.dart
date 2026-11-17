/// Requires a nonempty gateway secret, rejecting whitespace-only values
/// with an [ArgumentError].
String requireSecret(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(
      value.isEmpty ? value : '(blank)',
      name,
      'must not be empty or blank',
    );
  }
  return value;
}
