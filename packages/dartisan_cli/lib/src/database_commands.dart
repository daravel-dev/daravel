import 'dart:io';

import 'package:daravel/daravel.dart';

import '../dartisan_cli.dart';

/// `dartisan db:seed [--class=Name] [--all]` — runs database seeders.
final class DbSeedCommand extends DaravelCommand {
  DbSeedCommand(super.createApp) {
    argParser
      ..addOption(
        'class',
        help:
            'Seeder class name to run (default: the first registered seeder).',
      )
      ..addFlag(
        'all',
        negatable: false,
        help: 'Run every registered seeder in order.',
      );
  }

  @override
  String get name => 'db:seed';

  @override
  String get description => 'Seed the database with records.';

  @override
  Future<int> run() => withApp((app) async {
    final results = argResults!;
    final registry = App.make<SeederRegistry>();
    if (registry.seeders.isEmpty) {
      stdout.writeln(
        'No seeders registered (use ApplicationBuilder.withSeeders).',
      );
      return 0;
    }
    final ran = await registry.run(
      name: results['class'] as String?,
      all: results['all'] as bool,
    );
    for (final seeder in ran) {
      stdout.writeln('Seeded: $seeder');
    }
    return 0;
  });
}

/// `dartisan migrate:fresh [--seed]` — drops all tables and migrates.
final class MigrateFreshCommand extends DaravelCommand {
  MigrateFreshCommand(super.createApp) {
    argParser
      ..addFlag(
        'seed',
        negatable: false,
        help: 'Run the root seeder afterwards.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Required when APP_ENV=production.',
      );
  }

  @override
  String get name => 'migrate:fresh';

  @override
  String get description => 'Drop all tables and re-run all migrations.';

  @override
  Future<int> run() => withApp((app) async {
    final results = argResults!;
    if (app.config.section<AppConfig>().isProduction &&
        !(results['force'] as bool)) {
      stderr.writeln(
        'migrate:fresh is destructive; pass --force to run it in production.',
      );
      return 1;
    }
    final migrated = await App.make<Migrator>().fresh();
    stdout.writeln('Dropped all tables successfully.');
    for (final name in migrated) {
      stdout.writeln('Migrated: $name');
    }
    if (results['seed'] as bool) {
      for (final seeder in await App.make<SeederRegistry>().run()) {
        stdout.writeln('Seeded: $seeder');
      }
    }
    return 0;
  });
}
