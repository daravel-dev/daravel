/// Whether [granted] permissions imply [required], as Spatie's
/// `WildcardPermission` decides it (Apache Shiro's rules):
///
/// - parts are separated by `.`, alternatives within a part by `,`
///   (`posts.edit,delete`);
/// - `*` stands for any one part (`posts.*.own`);
/// - a shorter permission implies every longer one it starts
///   (`posts` and `posts.*` imply `posts.edit` and `posts.edit.own`).
///
/// Throws [FormatException] on an empty part (`posts..edit`), as Spatie's
/// `WildcardPermissionNotProperlyFormatted`.
bool wildcardImplies(Iterable<String> granted, String required) {
  final index = _Node();
  for (final permission in granted) {
    _add(index, permission.split('.'), permission);
  }
  return _check(index, required.split('.'));
}

final class _Node {
  final Map<String, _Node> children = {};
  bool terminal = false;
}

void _add(_Node node, List<String> parts, String permission) {
  if (parts.isEmpty) {
    node.terminal = true;
    return;
  }
  final part = parts.first;
  if (part.trim().isEmpty) {
    throw FormatException(
      'Wildcard permission `$permission` is not properly formatted.',
    );
  }
  for (final sub in part.split(',')) {
    if (sub.trim().isEmpty) {
      throw FormatException(
        'Wildcard permission `$permission` is not properly formatted.',
      );
    }
    _add(
      node.children.putIfAbsent(sub, _Node.new),
      parts.sublist(1),
      permission,
    );
  }
}

bool _check(_Node node, List<String> required) {
  if (node.terminal) {
    return true;
  }
  if (required.isEmpty) {
    return false;
  }
  final rest = required.sublist(1);
  final exact = node.children[required.first];
  if (exact != null && _check(exact, rest)) {
    return true;
  }
  final any = node.children['*'];
  return any != null && _check(any, rest);
}
