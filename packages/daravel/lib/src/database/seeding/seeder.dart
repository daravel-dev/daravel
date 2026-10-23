import 'dart:async';

/// Populates the database (`db:seed`). Seeders run inside the application's
/// command scope, so facades (`DB`, models, factories) are available.
abstract class Seeder {
  const Seeder();

  /// Human readable name (defaults to the class name).
  String get name => runtimeType.toString();

  Future<void> run();

  /// Runs [seeders] in order (Laravel `$this->call([...])`).
  Future<void> call(List<Seeder> seeders) async {
    for (final seeder in seeders) {
      await seeder.run();
    }
  }
}

/// Seeders registered with `ApplicationBuilder.withSeeders`. The first entry
/// is the root seeder run by a bare `db:seed` (Laravel's `DatabaseSeeder`).
final class SeederRegistry {
  SeederRegistry(List<Seeder> seeders) : seeders = List.unmodifiable(seeders);

  final List<Seeder> seeders;

  /// The seeder named [name] (class name), or `null`.
  Seeder? find(String name) {
    for (final seeder in seeders) {
      if (seeder.name == name) {
        return seeder;
      }
    }
    return null;
  }

  /// Runs the root seeder, or the one named [name].
  Future<List<String>> run({String? name, bool all = false}) async {
    if (seeders.isEmpty) {
      return const [];
    }
    final targets = all
        ? seeders
        : [
            if (name == null)
              seeders.first
            else
              find(name) ??
                  (throw ArgumentError.value(name, 'name', 'Unknown seeder')),
          ];
    for (final seeder in targets) {
      await seeder.run();
    }
    return [for (final seeder in targets) seeder.name];
  }
}
