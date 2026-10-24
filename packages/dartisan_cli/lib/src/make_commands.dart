import 'dart:io';

import 'package:args/command_runner.dart';

import 'generator.dart';

/// Base for `make:*` commands: no application boot needed.
abstract class MakeCommand extends Command<int> {
  MakeCommand() {
    argParser
      ..addFlag('force', negatable: false, help: 'Overwrite existing files.')
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Show what would be written without touching disk.',
      )
      ..addFlag(
        'no-registry',
        negatable: false,
        help: 'Do not update bootstrap registry files.',
      );
  }

  Generator generator() => Generator(
    ProjectPaths.locate(),
    force: argResults!['force'] as bool,
    dryRun: argResults!['dry-run'] as bool,
    updateRegistries: !(argResults!['no-registry'] as bool),
  );

  String get nameArgument {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      usageException('Missing <name> argument.');
    }
    return rest.first;
  }

  int report(Generator generator) {
    for (final entry in generator.log) {
      stdout.writeln(entry);
    }
    for (final hint in generator.hints) {
      stdout.writeln('  -> $hint');
    }
    return generator.log.any((e) => !e.skipped) ? 0 : 1;
  }
}

/// `make:model Name [-m] [-f] [-s] [-c] [--api] [--all] [--table=] [--soft-deletes]`
final class MakeModelCommand extends MakeCommand {
  MakeModelCommand() {
    argParser
      ..addFlag(
        'migration',
        abbr: 'm',
        negatable: false,
        help: 'Also create a migration.',
      )
      ..addFlag(
        'factory',
        abbr: 'f',
        negatable: false,
        help: 'Also create a factory.',
      )
      ..addFlag(
        'seeder',
        abbr: 's',
        negatable: false,
        help: 'Also create a seeder.',
      )
      ..addFlag(
        'controller',
        abbr: 'c',
        negatable: false,
        help: 'Also create a controller.',
      )
      ..addFlag(
        'api',
        negatable: false,
        help: 'Generated controller is an API resource.',
      )
      ..addFlag(
        'all',
        abbr: 'a',
        negatable: false,
        help: 'Migration, factory, seeder and controller.',
      )
      ..addFlag(
        'policy',
        abbr: 'p',
        negatable: false,
        help: 'Also create (and register) a policy.',
      )
      ..addFlag(
        'resource',
        abbr: 'r',
        negatable: false,
        help: 'Also create an API resource.',
      )
      ..addFlag(
        'soft-deletes',
        negatable: false,
        help: 'Enable soft deletes on the model.',
      )
      ..addOption(
        'table',
        help: 'Table name (default: snake_case plural of the model).',
      );
  }

  @override
  String get name => 'make:model';

  @override
  String get description => 'Create a new model class.';

  @override
  Future<int> run() async {
    final args = argResults!;
    final gen = generator();
    final model = nameArgument;
    final all = args['all'] as bool;
    gen.model(
      model,
      table: args['table'] as String?,
      softDeletes: args['soft-deletes'] as bool,
    );
    if (all || args['migration'] as bool) {
      final table =
          args['table'] as String? ?? Naming.table(Naming.pascal(model));
      gen.migration('create_${table}_table', create: table);
    }
    if (all || args['factory'] as bool) {
      gen.factory(model, model: model);
    }
    if (all || args['seeder'] as bool) {
      gen.seeder('${Naming.pascal(model)}Seeder');
    }
    if (all || args['controller'] as bool) {
      gen.controller(
        '${Naming.pascal(model)}Controller',
        api: args['api'] as bool,
        resource: true,
        model: model,
      );
    }
    if (all || args['policy'] as bool) {
      gen.policy('${Naming.pascal(model)}Policy', model: model);
    }
    if (all || args['resource'] as bool) {
      gen.resource('${Naming.pascal(model)}Resource', model: model);
    }
    return report(gen);
  }
}

/// `make:migration name [--create=table] [--table=table]`
final class MakeMigrationCommand extends MakeCommand {
  MakeMigrationCommand() {
    argParser
      ..addOption('create', help: 'Table to create.')
      ..addOption('table', help: 'Table to alter.');
  }

  @override
  String get name => 'make:migration';

  @override
  String get description => 'Create a new migration file (and register it).';

  @override
  Future<int> run() async {
    final gen = generator();
    final raw = nameArgument;
    var create = argResults!['create'] as String?;
    final table = argResults!['table'] as String?;
    final guessed = RegExp(r'^create_(\w+)_table$')
        .firstMatch(Naming.snake(raw));
    if (create == null && table == null && guessed != null) {
      create = guessed.group(1);
    }
    gen.migration(raw, create: create, table: table);
    return report(gen);
  }
}

/// `make:job Name`
final class MakeJobCommand extends MakeCommand {
  @override
  String get name => 'make:job';

  @override
  String get description => 'Create a new job class (and register it).';

  @override
  Future<int> run() async {
    final gen = generator();
    gen.job(nameArgument);
    return report(gen);
  }
}

/// `make:seeder Name`
final class MakeSeederCommand extends MakeCommand {
  @override
  String get name => 'make:seeder';

  @override
  String get description => 'Create a new seeder class (and register it).';

  @override
  Future<int> run() async {
    final gen = generator();
    gen.seeder(nameArgument);
    return report(gen);
  }
}

/// `make:factory Name [--model=]`
final class MakeFactoryCommand extends MakeCommand {
  MakeFactoryCommand() {
    argParser.addOption(
      'model',
      help: 'Model the factory builds (default: derived from the name).',
    );
  }

  @override
  String get name => 'make:factory';

  @override
  String get description => 'Create a new model factory.';

  @override
  Future<int> run() async {
    final gen = generator();
    gen.factory(nameArgument, model: argResults!['model'] as String?);
    return report(gen);
  }
}

/// `make:controller Name [--api] [--resource] [--model=]`
final class MakeControllerCommand extends MakeCommand {
  MakeControllerCommand() {
    argParser
      ..addFlag(
        'api',
        negatable: false,
        help: 'API resource controller (index/store/show/update/destroy).',
      )
      ..addFlag('resource', negatable: false, help: 'Resource controller.')
      ..addOption('model', help: 'Model the controller manages.');
  }

  @override
  String get name => 'make:controller';

  @override
  String get description => 'Create a new controller class.';

  @override
  Future<int> run() async {
    final gen = generator();
    gen.controller(
      nameArgument,
      api: argResults!['api'] as bool,
      resource: argResults!['resource'] as bool,
      model: argResults!['model'] as String?,
    );
    return report(gen);
  }
}

/// `make:request Name`
final class MakeRequestCommand extends MakeCommand {
  @override
  String get name => 'make:request';

  @override
  String get description => 'Create a new form request class.';

  @override
  Future<int> run() async {
    final gen = generator();
    gen.request(nameArgument);
    return report(gen);
  }
}

/// `make:middleware Name`
final class MakeMiddlewareCommand extends MakeCommand {
  @override
  String get name => 'make:middleware';

  @override
  String get description => 'Create a new middleware class.';

  @override
  Future<int> run() async {
    final gen = generator();
    gen.middleware(nameArgument);
    return report(gen);
  }
}

/// Generic `make:*` command for generators that take a name and optional
/// `--model` / `--event` options.
final class _SimpleMakeCommand extends MakeCommand {
  _SimpleMakeCommand(
    this.name,
    this.description,
    this._generate, {
    bool model = false,
    bool modelRequired = false,
    bool event = false,
  }) : _modelRequired = modelRequired {
    if (model || modelRequired) {
      argParser.addOption('model', help: 'Model the class works with.');
    }
    if (event) {
      argParser.addOption('event', help: 'Event the listener handles.');
    }
  }

  @override
  final String name;

  @override
  final String description;

  final bool _modelRequired;
  final void Function(Generator gen, String name, Map<String, String?> options)
  _generate;

  @override
  Future<int> run() async {
    final args = argResults!;
    final options = <String, String?>{
      for (final option in const ['model', 'event'])
        if (argParser.options.containsKey(option))
          option: args[option] as String?,
    };
    if (_modelRequired && options['model'] == null) {
      usageException('--model is required for $name.');
    }
    final gen = generator();
    _generate(gen, nameArgument, options);
    return report(gen);
  }
}

/// `make:policy`, `make:event`, `make:listener`, `make:resource`,
/// `make:rule`, `make:observer`, `make:provider`, `make:command`,
/// `make:test`.
List<Command<int>> extraMakeCommands() => [
  _SimpleMakeCommand(
    'make:policy',
    'Create a new policy class (registered with --model).',
    (g, n, o) => g.policy(n, model: o['model']),
    model: true,
  ),
  _SimpleMakeCommand(
    'make:event',
    'Create a new event class.',
    (g, n, o) => g.event(n),
  ),
  _SimpleMakeCommand(
    'make:listener',
    'Create a new listener (registered with --event).',
    (g, n, o) => g.listener(n, event: o['event']),
    event: true,
  ),
  _SimpleMakeCommand(
    'make:resource',
    'Create a new API resource.',
    (g, n, o) => g.resource(n, model: o['model']),
    model: true,
  ),
  _SimpleMakeCommand(
    'make:rule',
    'Create a new validation rule.',
    (g, n, o) => g.rule(n),
  ),
  _SimpleMakeCommand(
    'make:observer',
    'Create a new model observer.',
    (g, n, o) => g.observer(n, model: o['model']!),
    modelRequired: true,
  ),
  _SimpleMakeCommand(
    'make:provider',
    'Create a new service provider.',
    (g, n, o) => g.provider(n),
  ),
  MakeConsoleCommand(),
  MakeTestCommand(),
  StubPublishCommand(),
];

/// `make:command Name [--command=app:name]`
final class MakeConsoleCommand extends MakeCommand {
  MakeConsoleCommand() {
    argParser.addOption(
      'command',
      help: 'Terminal signature (default: app:<kebab-name>).',
    );
  }

  @override
  String get name => 'make:command';

  @override
  String get description => 'Create a new dartisan command (and register it).';

  @override
  Future<int> run() async {
    final gen = generator();
    gen.command(nameArgument, signature: argResults!['command'] as String?);
    return report(gen);
  }
}

/// `make:test Name [--unit]`
final class MakeTestCommand extends MakeCommand {
  MakeTestCommand() {
    argParser.addFlag('unit', negatable: false, help: 'Create a unit test.');
  }

  @override
  String get name => 'make:test';

  @override
  String get description => 'Create a new test.';

  @override
  Future<int> run() async {
    final gen = generator();
    gen.test(nameArgument, unit: argResults!['unit'] as bool);
    return report(gen);
  }
}

/// `stub:publish [--force]` — copies the generator templates to `stubs/`.
final class StubPublishCommand extends MakeCommand {
  @override
  String get name => 'stub:publish';

  @override
  String get description =>
      'Publish all stubs that are available for customization.';

  @override
  String get nameArgument => '';

  @override
  Future<int> run() async {
    final gen = generator();
    gen.publishStubs();
    final written = gen.log.where((e) => !e.skipped).length;
    stdout.writeln(
      '$written stub(s) published to stubs/ '
      '(${gen.log.length - written} already existed; use --force to overwrite).',
    );
    return 0;
  }
}
