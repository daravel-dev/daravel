import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;

import 'generator.dart';

String _envFile(String root, String? environment) =>
    p.join(root, environment == null ? '.env' : '.env.$environment');

String? _keyFromEnvironment() {
  for (final name in EnvironmentEncrypter.keyVariables) {
    final value = Platform.environment[name];
    if (value != null && value.isNotEmpty) {
      return value;
    }
  }
  return null;
}

/// `env:encrypt [--key] [--cipher] [--env] [--readable] [--prune] [--force]`
/// — writes `.env.encrypted`, compatible with `php artisan env:encrypt`.
final class EnvEncryptCommand extends Command<int> {
  EnvEncryptCommand({this.root}) {
    argParser
      ..addOption('key', help: 'Encryption key (base64:... or 32 characters).')
      ..addOption(
        'cipher',
        defaultsTo: 'AES-256-CBC',
        allowed: ['AES-256-CBC', 'AES-256-GCM'],
        help: 'Encryption cipher.',
      )
      ..addOption('env', help: 'Encrypt .env.<env> instead of .env.')
      ..addFlag(
        'readable',
        negatable: false,
        help: 'Encrypt each value separately and keep the names readable.',
      )
      ..addFlag(
        'prune',
        negatable: false,
        help: 'Delete the plain file afterwards.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Overwrite an existing encrypted file.',
      );
  }

  /// Project root; located from the working directory when `null`.
  final String? root;

  @override
  String get name => 'env:encrypt';

  @override
  String get description => 'Encrypt an environment file.';

  @override
  Future<int> run() async {
    final args = argResults!;
    final plain = File(
      _envFile(root ?? ProjectPaths.locate().root, args['env'] as String?),
    );
    final target = File('${plain.path}.encrypted');
    if (!plain.existsSync()) {
      stderr.writeln('Environment file not found: ${plain.path}');
      return 1;
    }
    if (target.existsSync() && !(args['force'] as bool)) {
      stderr.writeln(
        'Encrypted environment file already exists; use --force to replace it.',
      );
      return 1;
    }
    final passed = args['key'] as String?;
    final key = passed ?? Encrypter.generateKey();
    final cipher = EncryptionCipher.parse(args['cipher'] as String);
    final EnvironmentEncrypter encrypter;
    try {
      encrypter = EnvironmentEncrypter(key, cipher: cipher);
    } on EncryptException catch (error) {
      stderr.writeln(error.message);
      return 1;
    }
    target.writeAsStringSync(
      await encrypter.encrypt(
        plain.readAsStringSync(),
        readable: args['readable'] as bool,
      ),
    );
    if (args['prune'] as bool) {
      plain.deleteSync();
    }
    stdout
      ..writeln('Environment successfully encrypted.')
      ..writeln('  Key            $key')
      ..writeln('  Cipher         ${args['cipher']}')
      ..writeln('  Encrypted file ${target.path}');
    if (passed == null) {
      stdout.writeln(
        '\nStore the key in your secret manager. At runtime, set '
        'DARAVEL_ENV_ENCRYPTION_KEY (or LARAVEL_ENV_ENCRYPTION_KEY) and the '
        'application decrypts the file in memory at boot.',
      );
    }
    return 0;
  }
}

/// `env:decrypt [--key] [--env] [--filename] [--path] [--force]` — writes
/// the plain file back, compatible with `php artisan env:decrypt`.
final class EnvDecryptCommand extends Command<int> {
  EnvDecryptCommand({this.root}) {
    argParser
      ..addOption(
        'key',
        help:
            'Decryption key (default: DARAVEL_ENV_ENCRYPTION_KEY or '
            'LARAVEL_ENV_ENCRYPTION_KEY).',
      )
      ..addOption(
        'cipher',
        help: 'Accepted for compatibility; the payload names its cipher.',
      )
      ..addOption('env', help: 'Decrypt .env.<env>.encrypted.')
      ..addOption('filename', help: 'Output file name.')
      ..addOption('path', help: 'Output directory.')
      ..addFlag(
        'force',
        negatable: false,
        help: 'Overwrite an existing environment file.',
      );
  }

  /// Project root; located from the working directory when `null`.
  final String? root;

  @override
  String get name => 'env:decrypt';

  @override
  String get description => 'Decrypt an encrypted environment file.';

  @override
  Future<int> run() async {
    final args = argResults!;
    final key = args['key'] as String? ?? _keyFromEnvironment();
    if (key == null) {
      stderr.writeln(
        'A decryption key is required (--key or '
        'DARAVEL_ENV_ENCRYPTION_KEY).',
      );
      return 1;
    }
    final projectRoot = root ?? ProjectPaths.locate().root;
    final environment = args['env'] as String?;
    final source = File('${_envFile(projectRoot, environment)}.encrypted');
    final fileName =
        args['filename'] as String? ??
        (environment == null ? '.env' : '.env.$environment');
    if (fileName.endsWith('.encrypted')) {
      stderr.writeln('Invalid filename.');
      return 1;
    }
    final output = File(
      p.join(args['path'] as String? ?? projectRoot, fileName),
    );
    if (!source.existsSync()) {
      stderr.writeln('Encrypted environment file not found: ${source.path}');
      return 1;
    }
    if (output.existsSync() && !(args['force'] as bool)) {
      stderr.writeln(
        'Environment file already exists; use --force to replace it.',
      );
      return 1;
    }
    try {
      output.writeAsStringSync(
        await EnvironmentEncrypter(key).decrypt(source.readAsStringSync()),
      );
    } on DaravelException catch (error) {
      stderr.writeln('Could not decrypt: ${error.message}');
      return 1;
    }
    stdout
      ..writeln('Environment successfully decrypted.')
      ..writeln('  Decrypted file ${output.path}');
    return 0;
  }
}

/// `env:obfuscate [--env] [--output] [--class] [--only]` — writes a Dart
/// file holding the values XOR-masked with random bytes, so they do not
/// appear as plain strings in a compiled binary.
///
/// This is obfuscation, not encryption: the mask ships in the same binary.
/// Use `env:encrypt` for secrets kept in a repository.
final class EnvObfuscateCommand extends Command<int> {
  EnvObfuscateCommand({this.root, Random? random})
    : _random = random ?? Random.secure() {
    argParser
      ..addOption('env', help: 'Read .env.<env> instead of .env.')
      ..addOption(
        'output',
        defaultsTo: 'lib/config/obfuscated_env.dart',
        help: 'Generated Dart file.',
      )
      ..addOption(
        'class',
        defaultsTo: 'ObfuscatedEnv',
        help: 'Name of the generated class.',
      )
      ..addMultiOption(
        'only',
        help: 'Variables to include (default: all).',
        splitCommas: true,
      );
  }

  /// Project root; located from the working directory when `null`.
  final String? root;
  final Random _random;

  @override
  String get name => 'env:obfuscate';

  @override
  String get description =>
      'Generate a Dart class with XOR-masked environment values.';

  @override
  Future<int> run() async {
    final args = argResults!;
    final projectRoot = root ?? ProjectPaths.locate().root;
    final source = File(_envFile(projectRoot, args['env'] as String?));
    if (!source.existsSync()) {
      stderr.writeln('Environment file not found: ${source.path}');
      return 1;
    }
    final only = (args['only'] as List<String>).toSet();
    final values = Env.parse(source.readAsStringSync());
    final selected = <String, String>{
      for (final entry in values.entries)
        if (only.isEmpty || only.contains(entry.key)) entry.key: entry.value,
    };
    final output = File(p.join(projectRoot, args['output'] as String));
    output.parent.createSync(recursive: true);
    output.writeAsStringSync(
      renderObfuscatedEnv(selected, className: args['class'] as String),
    );
    stdout.writeln(
      'Wrote ${selected.length} variable(s) to '
      '${p.relative(output.path, from: projectRoot)}.',
    );
    return 0;
  }

  /// Renders the generated library for [values].
  String renderObfuscatedEnv(
    Map<String, String> values, {
    String className = 'ObfuscatedEnv',
  }) {
    final buffer = StringBuffer()
      ..writeln('// GENERATED by `dartisan env:obfuscate`. Do not edit.')
      ..writeln('//')
      ..writeln('// Values are XOR-masked so they do not appear as plain')
      ..writeln('// strings in the binary. This is obfuscation, not')
      ..writeln('// encryption: do not commit this file for real secrets.')
      ..writeln('// ignore_for_file: lines_longer_than_80_chars')
      ..writeln()
      ..writeln("import 'dart:convert';")
      ..writeln()
      ..writeln('abstract final class $className {')
      ..writeln('  static String _d(List<int> k, List<int> v) => utf8.decode(')
      ..writeln(
        '    List<int>.generate(v.length, (i) => v[i] ^ k[i], '
        'growable: false),',
      )
      ..writeln('  );');
    final getters = <String, String>{};
    for (final MapEntry(key: name, value: value) in values.entries) {
      final getter = _camel(name);
      getters[name] = getter;
      final bytes = utf8.encode(value);
      final mask = [
        for (var i = 0; i < bytes.length; i++) _random.nextInt(256),
      ];
      final masked = [
        for (var i = 0; i < bytes.length; i++) bytes[i] ^ mask[i],
      ];
      final suffix = '${getter[0].toUpperCase()}${getter.substring(1)}';
      buffer
        ..writeln()
        ..writeln('  static const List<int> _k$suffix = <int>${_list(mask)};')
        ..writeln('  static const List<int> _v$suffix = <int>${_list(masked)};')
        ..writeln('  static String get $getter => _d(_k$suffix, _v$suffix);');
    }
    buffer
      ..writeln()
      ..writeln('  /// Every value, keyed by its variable name; pass it to')
      ..writeln('  /// `createApp(env: $className.toMap())`.')
      ..writeln('  static Map<String, String> toMap() => <String, String>{');
    for (final MapEntry(key: name, value: getter) in getters.entries) {
      buffer.writeln("    '$name': $getter,");
    }
    buffer
      ..writeln('  };')
      ..writeln('}');
    return buffer.toString();
  }

  static String _list(List<int> bytes) =>
      '[${bytes.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(', ')}]';

  static String _camel(String name) {
    final parts = name
        .toLowerCase()
        .split(RegExp('[^a-z0-9]+'))
        .where((part) => part.isNotEmpty)
        .toList();
    final camel = [
      parts.first,
      for (final part in parts.skip(1))
        '${part[0].toUpperCase()}${part.substring(1)}',
    ].join();
    return RegExp(r'^[0-9]').hasMatch(camel) ? 'v$camel' : camel;
  }
}
