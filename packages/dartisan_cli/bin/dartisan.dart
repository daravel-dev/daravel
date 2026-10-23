import 'dart:io';

/// Global entrypoint. Tier 0 only supports the project-bound runner; the
/// global `dartisan new` scaffolder arrives in slice S12.
void main(List<String> args) {
  stdout.writeln(
    'dartisan (global) — run commands from inside a Daravel project:\n'
    '  dart run bin/dartisan.dart <command>\n'
    'Available in Tier 0: serve, route:list, migrate, migrate:status, '
    'migrate:rollback, migrate:reset.',
  );
  exit(args.isEmpty ? 0 : 64);
}
