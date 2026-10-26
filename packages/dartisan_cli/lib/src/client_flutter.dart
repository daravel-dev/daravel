import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;

import '../dartisan_cli.dart';
import 'client_runtime.dart';

/// `client:flutter [--output=../app_client] [--package-name=app_client]`:
/// generates a typed Dart client package (Flutter and plain Dart) from the
/// application's routes (Blueprint #25).
///
/// It reads the booted route table, like `openapi:generate`: `.validates()`
/// and `.rules()` become input classes with the server's own rules checked
/// on the device (messages resolved by the server's translator), and
/// `.returns()` becomes models and Laravel's paginators.
final class ClientFlutterCommand extends DaravelCommand {
  ClientFlutterCommand(super.createApp) {
    argParser
      ..addOption(
        'output',
        defaultsTo: '../app_client',
        help: 'Directory of the generated package (relative to the app).',
      )
      ..addOption(
        'package-name',
        defaultsTo: 'app_client',
        help: 'Name of the generated package.',
      )
      ..addOption(
        'prefix',
        defaultsTo: '/api',
        help:
            'Only routes under this path (all routes when none match; '
            '`/` for all).',
      )
      ..addMultiOption(
        'state',
        allowed: clientStates,
        help: 'State adapters to generate (comma-separated).',
      )
      ..addOption('base-url', help: 'Default base URL (default: APP_URL).')
      ..addFlag(
        'watch',
        negatable: false,
        help: 'Regenerate when routes, requests, resources or .env change.',
      )
      ..addOption(
        'locale',
        help: 'Locale of the validation messages (default: APP_LOCALE).',
      );
  }

  @override
  String get name => 'client:flutter';

  @override
  String get description =>
      'Generate a typed Dart/Flutter API client from the routes.';

  /// The generated package's directory and the app's, set by [_generate].
  String? _output;
  String? _base;

  @override
  Future<int> run() async {
    final code = await withApp(_generate);
    final output = _output;
    final base = _base;
    if (code != 0 || argResults!['watch'] != true || output == null) {
      return code;
    }
    // Every run needs a fresh process: the routes are compiled in.
    final script = Platform.script.toFilePath();
    final args = [
      'run',
      if (script.endsWith('.dart')) script else 'bin/dartisan.dart',
      'client:flutter',
      for (final arg in argResults!.arguments)
        if (arg != '--watch') arg,
    ];
    final watcher = ClientWatcher(
      root: base!,
      exclude: output,
      regenerate: () async {
        final result = await Process.run(
          Platform.resolvedExecutable,
          args,
          workingDirectory: base,
        );
        stdout.write(result.stdout);
        stderr.write(result.stderr);
        return result.exitCode;
      },
    );
    await watcher.start();
    final unwatch = watchStopSignals(() => unawaited(watcher.stop()));
    await watcher.done;
    await unwatch();
    return 0;
  }

  Future<int> _generate(Application app) async {
    final config = app.config.section<AppConfig>();
    final packageName = argResults!['package-name'] as String;
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(packageName)) {
      stderr.writeln('Invalid package name: $packageName');
      return 64;
    }
    final client = generateClient(
      routesUnder(app.router.routes, argResults!['prefix'] as String),
      packageName: packageName,
      baseUrl: argResults!['base-url'] as String? ?? config.url,
      locale: argResults!['locale'] as String? ?? config.locale,
      title: config.name,
      states: (argResults!['state'] as List<String>).toSet(),
    );
    final output = argResults!['output'] as String;
    final root = p.normalize(
      p.isAbsolute(output) ? output : p.join(app.basePath, output),
    );
    await writeClient(client, root);
    stdout.writeln(
      'Wrote $packageName to ${p.relative(root, from: app.basePath)}: '
      '${client.operations} operation(s), ${client.models} model(s), '
      '${client.inputs} input(s).',
    );
    for (final note in client.notes) {
      stdout.writeln('  note: $note');
    }
    _output = root;
    _base = app.basePath;
    return 0;
  }
}

/// A generated client: [files] by path relative to the package root.
final class GeneratedClient {
  GeneratedClient(
    this.files, {
    required this.operations,
    required this.models,
    required this.inputs,
    required this.notes,
  });

  final Map<String, String> files;
  final int operations;
  final int models;
  final int inputs;

  /// What the client leaves to the server (rules it cannot check, ...).
  final List<String> notes;
}

/// Files written only when missing, so the package can be edited (extra
/// dependencies, README).
const Set<String> _keptFiles = {'pubspec.yaml', 'analysis_options.yaml'};

/// Writes [client] under [root] and formats it.
Future<void> writeClient(GeneratedClient client, String root) async {
  for (final path in _optionalFiles) {
    final file = File(p.join(root, path));
    if (!client.files.containsKey(path) && file.existsSync()) {
      await file.delete();
    }
  }
  final pubspec = File(p.join(root, 'pubspec.yaml'));
  if (pubspec.existsSync()) {
    // Kept as edited: name what a new `--state` needs instead.
    final text = pubspec.readAsStringSync();
    final wanted = RegExp(r'^  (\w+): ', multiLine: true)
        .allMatches(client.files['pubspec.yaml'] ?? '')
        .map((m) => m[1]!)
        .where((name) => name != 'sdk');
    for (final name in wanted) {
      if (!RegExp('^  $name:', multiLine: true).hasMatch(text)) {
        client.notes.add('add `$name` to ${pubspec.path}');
      }
    }
  }
  for (final MapEntry(key: path, value: content) in client.files.entries) {
    final file = File(p.join(root, path));
    if (_keptFiles.contains(path) && file.existsSync()) {
      continue;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }
  final dart = Platform.resolvedExecutable;
  if (p.basenameWithoutExtension(dart) == 'dart') {
    await Process.run(dart, ['format', p.join(root, 'lib')]);
  }
}

/// The routes under [prefix] (`/api`), or all of them when none are.
List<RouteEntry> routesUnder(Iterable<RouteEntry> routes, String prefix) {
  final base = prefix.endsWith('/') && prefix.length > 1
      ? prefix.substring(0, prefix.length - 1)
      : prefix;
  if (base == '/' || base.isEmpty) {
    return routes.toList();
  }
  final under = [
    for (final route in routes)
      if (route.path == base || route.path.startsWith('$base/')) route,
  ];
  return under.isEmpty ? routes.toList() : under;
}

/// Builds the client package for [routes].
GeneratedClient generateClient(
  Iterable<RouteEntry> routes, {
  required String packageName,
  required String baseUrl,
  String locale = 'en',
  String title = 'Daravel',
  Set<String> states = const <String>{},
}) => _Generator(packageName, baseUrl, locale, title, states).run(routes);

/// Dart's reserved words (and `await`/`yield`, reserved in async code):
/// not usable as names. Built-in and contextual identifiers (`get`, `show`,
/// `on`, `type`, ...) are fine as member names.
const Set<String> _reserved = {
  'assert',
  'await',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'default',
  'do',
  'else',
  'enum',
  'extends',
  'false',
  'final',
  'finally',
  'for',
  'if',
  'in',
  'is',
  'new',
  'null',
  'rethrow',
  'return',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'var',
  'void',
  'while',
  'with',
  'yield',
};

/// Members of the generated client class that operations must not shadow.
const Set<String> _clientMembers = {
  'baseUri',
  'tokens',
  'requestHeaders',
  'uri',
  'webSocketUri',
  'send',
  'events',
  'close',
  'hashCode',
  'runtimeType',
  'toString',
};

List<String> _words(String text) => text
    .replaceAllMapped(RegExp('([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}')
    .split(RegExp('[^A-Za-z0-9]+'))
    .where((w) => w.isNotEmpty)
    .toList();

String _pascal(String text) =>
    _words(text)
        .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join();

String _camel(String text) {
  final pascal = _pascal(text);
  if (pascal.isEmpty) {
    return 'value';
  }
  var name = pascal[0].toLowerCase() + pascal.substring(1);
  if (RegExp('^[0-9]').hasMatch(name)) {
    name = 'v$name';
  }
  return _reserved.contains(name) ? '${name}Value' : name;
}

/// [value] escaped for a single-quoted Dart string.
String _escape(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll("'", r"\'")
    .replaceAll(r'$', r'\$')
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\r');

/// A Dart string literal of [value].
String _str(String value) => "'${_escape(value)}'";

/// A const Dart literal of a JSON-ish [value], or `null` when it has none.
String? _literal(Object? value) => switch (value) {
  null => 'null',
  String() => _str(value),
  bool() || int() => '$value',
  double() when value.isFinite => '$value',
  _ => null,
};

/// How a JSON Schema maps to Dart: the type and the code converting a
/// decoded JSON value to it and back.
final class _Type {
  const _Type(this.name, this._decode, this._encode, {this.binary = false});

  final String name;
  final String Function(String json) _decode;
  final String Function(String value, bool nullable)? _encode;

  /// A file upload (`format: binary`): a multipart part, not JSON.
  final bool binary;

  String decode(String json, {required bool nullable}) =>
      nullable ? '$json == null ? null : ${_decode(json)}' : _decode(json);

  String encode(String value, {required bool nullable}) =>
      _encode?.call(value, nullable) ?? value;

  String typeName({required bool nullable}) =>
      nullable && !name.endsWith('?') ? '$name?' : name;
}

const _Type _object = _Type('Object?', _same, null);

String _same(String json) => json;

final class _Field {
  _Field(this.key, this.type, {required this.required, required this.nullable})
    : name = _camel(key);

  final String key;
  final String name;
  final _Type type;

  /// In the schema's `required` list.
  final bool required;

  /// May be `null` (not required, or `null` in the type).
  final bool nullable;
}

final class _Generator {
  _Generator(
    this.packageName,
    this.baseUrl,
    this.locale,
    this.title,
    this.states,
  );

  final String packageName;

  /// State adapters to generate ([clientStates]).
  final Set<String> states;
  final List<_Op> _ops = <_Op>[];
  final String baseUrl;
  final String locale;
  final String title;

  final StringBuffer _models = StringBuffer();
  final StringBuffer _inputs = StringBuffer();
  final Map<String, StringBuffer> _groups = <String, StringBuffer>{};
  final StringBuffer _root = StringBuffer();
  final Set<String> _modelNames = <String>{};
  final Set<String> _methodNames = <String>{};
  final List<String> _notes = <String>[];
  var _operations = 0;
  var _inputCount = 0;
  var _usesHttp = false;

  String get _clientClass => _pascal(packageName);

  GeneratedClient run(Iterable<RouteEntry> routes) {
    for (final route in routes) {
      if ((route.routeName ?? '').startsWith('daravel.') || route.isFallback) {
        continue;
      }
      _operation(route);
    }
    final files = <String, String>{
      'pubspec.yaml': _pubspec(),
      'analysis_options.yaml': _analysisOptions,
      'lib/$packageName.dart': _barrel(),
      'lib/src/runtime.dart': clientRuntimeSource,
      'lib/src/models.dart': _file(_models, importHttp: false),
      'lib/src/inputs.dart': _file(_inputs, importHttp: _usesHttp),
      'lib/src/api.dart': _api(),
      if (states.contains('bloc') || states.contains('cubit'))
        'lib/src/remote_state.dart': _remoteState(),
      if (states.contains('riverpod')) 'lib/src/providers.dart': _providers(),
      if (states.contains('bloc')) 'lib/src/blocs.dart': _blocs(),
      if (states.contains('cubit')) 'lib/src/cubits.dart': _cubits(),
    };
    return GeneratedClient(
      files,
      operations: _operations,
      models: _modelNames.length,
      inputs: _inputCount,
      notes: _notes,
    );
  }

  // -------------------------------------------------------------------------
  // Operations
  // -------------------------------------------------------------------------

  void _operation(RouteEntry route) {
    final verb = route.methods.firstWhere(
      (m) => m != 'HEAD' && m != 'OPTIONS',
      orElse: () => '',
    );
    if (verb.isEmpty) {
      return;
    }
    final (group, method) = _names(route, verb);
    final out = group.isEmpty
        ? _root
        : _groups.putIfAbsent(group, StringBuffer.new);
    var methodName = method;
    if (group.isEmpty && _clientMembers.contains(methodName)) {
      methodName = '${methodName}Route';
    }
    while (!_methodNames.add('$group.$methodName')) {
      methodName = '${methodName}2';
    }
    final base = '${_pascal(group)}${_pascal(methodName)}';
    final target = group.isEmpty ? '' : '_client.';
    final middleware = route.middlewareEntries.whereType<String>();
    final auth = middleware.any((m) => m == 'auth' || m.startsWith('auth:'));
    final doc = StringBuffer(
      '  /// `${route.isWebSocket ? 'WebSocket' : verb} ${route.path}`'
      '${route.routeName == null ? '' : ' (`${route.routeName}`)'}'
      '${auth ? ', needs a token' : ''}.\n',
    );
    final summary = route.summaryText;
    if (summary != null) {
      doc.write('  ///\n  /// $summary\n');
    }

    // Path parameters, positional. The path is built piece by piece: static
    // text escaped, parameters URL-encoded.
    final positional = <String>[];
    final pathCode = StringBuffer();
    var last = 0;
    for (final match in RegExp(r'(/?)\{(\w+)(\??)\}').allMatches(route.path)) {
      pathCode.write(_escape(route.path.substring(last, match.start)));
      last = match.end;
      final name = match[2]!;
      final optional = match[3] == '?';
      final number =
          route.constraints[name]?.pattern == RoutePatterns.number.pattern;
      final dartName = _camel(name);
      final type = number ? 'int' : 'String';
      positional.add(optional ? '[$type? $dartName]' : '$type $dartName');
      final encoded = '\${Uri.encodeComponent($dartName.toString())}';
      final slash = match[1]!;
      pathCode.write(
        optional
            ? "\${$dartName == null ? '' : '$slash$encoded'}"
            : '$slash$encoded',
      );
    }
    pathCode.write(_escape(route.path.substring(last)));
    final pathLiteral = "'$pathCode'";
    final required = positional.where((p) => !p.startsWith('[')).toList();
    final optional = positional.where((p) => p.startsWith('[')).toList();

    if (route.isWebSocket) {
      _operations++;
      final params = [
        ...required,
        if (optional.isNotEmpty) '[${optional.map(_unbracket).join(', ')}]',
      ].join(', ');
      out
        ..write(doc)
        ..write(
          '  ///\n  /// Connect with `${target}requestHeaders()` as headers.\n',
        )
        ..write(
          '  Uri $methodName($params) => ${target}webSocketUri($pathLiteral);\n\n',
        );
      return;
    }

    final write = const {'POST', 'PUT', 'PATCH', 'DELETE'}.contains(verb);
    final rules = route.documentedRules();
    final response = route.declaredResponse;
    final named = <String>[];
    final call = StringBuffer();
    String? inputClass;
    if (rules != null && rules.isNotEmpty) {
      inputClass = '${base}Input';
      final fields = _input(inputClass, route, verb, rules);
      for (final field in fields) {
        named.add(
          field.required && !field.nullable
              ? 'required ${field.type.typeName(nullable: false)} ${field.name}'
              : '${field.type.typeName(nullable: true)} ${field.name}',
        );
      }
      call.write(
        '    final input = $inputClass('
        '${fields.map((f) => '${f.name}: ${f.name}').join(', ')});\n',
      );
    }
    final pageParam = switch (response?.shape) {
      ResponseShape.paginated || ResponseShape.simplePaginated => 'page',
      ResponseShape.cursorPaginated => 'cursor',
      _ => null,
    };
    final hasPageField =
        pageParam != null && (rules?.keys.contains(pageParam) ?? false);
    if (pageParam != null && !hasPageField) {
      named.add(pageParam == 'page' ? 'int? page' : 'String? cursor');
    }
    if (inputClass == null) {
      named.add(
        write ? 'Map<String, Object?>? body' : 'Map<String, Object?>? query',
      );
    }
    final args = <String>[
      _str(verb),
      pathLiteral,
      if (inputClass != null && write) ...[
        'body: input.toJson()',
        if (_inputHasFiles(inputClass)) 'files: input.files',
      ],
      if (inputClass != null && !write)
        pageParam != null && !hasPageField
            ? "query: {...input.toJson(), '$pageParam': $pageParam}"
            : 'query: input.toJson()',
      if (inputClass == null && write) 'body: body',
      if (inputClass == null && !write)
        pageParam != null
            ? "query: {...?query, '$pageParam': $pageParam}"
            : 'query: query',
    ];
    final (returnType, convert) = _response(route, response, base);
    // Dart has no optional positional and named parameters together: with
    // named ones, optional path parameters become named too.
    final positionalOptional = named.isEmpty ? optional : const <String>[];
    if (named.isNotEmpty) {
      named.insertAll(0, optional.map(_unbracket));
    }
    final params = [
      ...required,
      if (positionalOptional.isNotEmpty)
        '[${positionalOptional.map(_unbracket).join(', ')}]',
      if (named.isNotEmpty) '{${named.join(', ')}}',
    ];
    _ops.add(
      _Op(
        group: group,
        method: methodName,
        returnType: returnType,
        query: verb == 'GET',
        doc: '`$verb ${route.path}`',
        params: [
          for (final param in required) _Param.parse(param, named: false),
          for (final param in positionalOptional)
            _Param.parse(_unbracket(param), named: false, optional: true),
          for (final param in named) _Param.parse(param, named: true),
        ],
      ),
    );
    _operations++;
    out
      ..write(doc)
      ..write(
        '  Future<$returnType> $methodName(${params.join(', ')}) async {\n',
      )
      ..write(call)
      ..write(
        returnType == 'void'
            ? '    await ${target}send(${args.join(', ')});\n'
            : '    final json = await ${target}send(${args.join(', ')});\n'
                  '    return $convert;\n',
      )
      ..write('  }\n\n');
  }

  String _unbracket(String param) => param.substring(1, param.length - 1);

  /// The group (resource class) and method name of [route]: `users.index`
  /// is `users` / `index`; unnamed routes go on the client itself.
  (String, String) _names(RouteEntry route, String verb) {
    final name = route.routeName;
    if (name != null && name.isNotEmpty) {
      final parts = name.split('.');
      if (parts.length == 1) {
        return ('', _camel(parts.single));
      }
      return (
        _camel(parts.sublist(0, parts.length - 1).join('_')),
        _camel(parts.last),
      );
    }
    final segments = route.path
        .split('/')
        .where((s) => s.isNotEmpty && s != 'api')
        .map(
          (s) =>
              s.startsWith('{') ? 'by_${s.replaceAll(RegExp('[{}?]'), '')}' : s,
        )
        .join('_');
    final prefix = route.isWebSocket ? 'socket' : verb.toLowerCase();
    return ('', _camel('${prefix}_$segments'));
  }

  (String, String) _response(
    RouteEntry route,
    RouteResponse? response,
    String base,
  ) {
    if (response == null) {
      return ('Object?', 'json');
    }
    final status = response.status;
    if (status == 204) {
      return ('void', 'null');
    }
    final model = _modelFor(response.schema, response.name ?? '${base}Item');
    final item = model.decode('e', nullable: false);
    final itemFn = item == 'e' ? '(e) => e' : '(e) => $item';
    final data = "jsonObject(json)['data']";
    return switch (response.shape) {
      ResponseShape.item => (model.name, model.decode(data, nullable: false)),
      ResponseShape.raw => (model.name, model.decode('json', nullable: false)),
      ResponseShape.collection => (
        'List<${model.name}>',
        'jsonArray($data).map($itemFn).toList()',
      ),
      ResponseShape.paginated => (
        'Page<${model.name}>',
        'Page.fromJson(json, $itemFn)',
      ),
      ResponseShape.simplePaginated => (
        'SimplePage<${model.name}>',
        'SimplePage.fromJson(json, $itemFn)',
      ),
      ResponseShape.cursorPaginated => (
        'CursorPage<${model.name}>',
        'CursorPage.fromJson(json, $itemFn)',
      ),
    };
  }

  // -------------------------------------------------------------------------
  // Models
  // -------------------------------------------------------------------------

  /// The Dart type of a response [schema], generating model classes for
  /// objects with properties ([name] for this one).
  _Type _modelFor(Map<String, Object?> schema, String name) =>
      _typeOf(schema, name, models: true);

  _Type _typeOf(
    Map<String, Object?> schema,
    String name, {
    required bool models,
  }) {
    final ref = schema[r'$ref'];
    if (ref is String && ref.startsWith('#/components/schemas/')) {
      final model = _pascal(ref.split('/').last);
      return _Type(
        model,
        (json) => '$model.fromJson($json)',
        (value, nullable) => nullable ? '$value?.toJson()' : '$value.toJson()',
      );
    }
    final type = _primaryType(schema);
    final format = schema['format'];
    switch (type) {
      case 'integer':
        return const _Type('int', _toInt, null);
      case 'number':
        return const _Type('num', _asNum, null);
      case 'boolean':
        return const _Type('bool', _asBool, null);
      case 'string' when format == 'binary':
        _usesHttp = true;
        return const _Type('http.MultipartFile', _same, null, binary: true);
      case 'string' when models && (format == 'date-time' || format == 'date'):
        return const _Type('DateTime', _toDateTime, _fromDateTime);
      case 'string':
        return const _Type('String', _asString, null);
      case 'array':
        final items = schema['items'];
        final item = items is Map<String, Object?>
            ? _typeOf(items, '${name}Item', models: models)
            : _object;
        final decodeItem = item.decode('e', nullable: false);
        final encodeItem = item.encode('e', nullable: false);
        return _Type(
          'List<${item.name}>',
          (json) => decodeItem == 'e'
              ? 'jsonArray($json)'
              : 'jsonArray($json).map((e) => $decodeItem).toList()',
          encodeItem == 'e'
              ? null
              : (value, nullable) =>
                    '$value${nullable ? '?' : ''}.map((e) => $encodeItem).toList()',
        );
      case 'object':
        final properties = schema['properties'];
        if (models && properties is Map && properties.isNotEmpty) {
          // A `title` names the model, so one schema reused in several
          // responses (`UserResource.schema`) is one class.
          final title = schema['title'];
          final model = _pascal(title is String ? title : name);
          _emitModel(model, schema);
          return _Type(
            model,
            (json) => '$model.fromJson($json)',
            (value, nullable) =>
                nullable ? '$value?.toJson()' : '$value.toJson()',
          );
        }
        return const _Type('Map<String, Object?>', _toMap, null);
      default:
        return _object;
    }
  }

  static String? _primaryType(Map<String, Object?> schema) {
    final type = schema['type'];
    if (type is String) {
      return type;
    }
    if (type is List) {
      return type.whereType<String>().where((t) => t != 'null').firstOrNull;
    }
    return schema['properties'] is Map ? 'object' : null;
  }

  static bool _nullableType(Map<String, Object?> schema) {
    final type = schema['type'];
    return schema['nullable'] == true ||
        (type is List && type.contains('null'));
  }

  List<_Field> _fields(
    Map<String, Object?> schema,
    String owner, {
    required bool models,
  }) {
    final properties = schema['properties'];
    if (properties is! Map) {
      return const <_Field>[];
    }
    final required = (schema['required'] as List<Object?>?) ?? const [];
    return [
      for (final MapEntry(:key, :value) in properties.entries)
        if (value is Map<String, Object?>)
          _Field(
            '$key',
            _typeOf(value, '$owner${_pascal('$key')}', models: models),
            required: required.contains(key),
            nullable: !required.contains(key) || _nullableType(value),
          ),
    ];
  }

  void _emitModel(String name, Map<String, Object?> schema) {
    if (!_modelNames.add(name)) {
      return;
    }
    final fields = _fields(schema, name, models: true);
    final out = StringBuffer();
    final description = schema['description'];
    out.write(
      description is String
          ? '/// $description\n'
          : '/// The `$name` returned by the API.\n',
    );
    out
      ..write('final class $name {\n')
      ..write(
        '  const $name({${fields.map((f) => '${f.nullable ? '' : 'required '}this.${f.name}').join(', ')}});\n\n',
      )
      ..write('  factory $name.fromJson(Object? json) {\n')
      ..write('    final map = jsonObject(json);\n')
      ..write('    return $name(\n');
    for (final field in fields) {
      out.write(
        '      ${field.name}: ${field.type.decode("map[${_str(field.key)}]", nullable: field.nullable)},\n',
      );
    }
    out.write('    );\n  }\n\n');
    for (final field in fields) {
      out.write(
        '  final ${field.type.typeName(nullable: field.nullable)} ${field.name};\n',
      );
    }
    out.write('\n  Map<String, Object?> toJson() => {\n');
    for (final field in fields) {
      out.write(
        '        ${_str(field.key)}: ${field.type.encode(field.name, nullable: field.nullable)},\n',
      );
    }
    out.write('      };\n}\n\n');
    _models.write(out);
  }

  // -------------------------------------------------------------------------
  // Inputs and client-side validation
  // -------------------------------------------------------------------------

  final Map<String, bool> _inputFiles = <String, bool>{};

  bool _inputHasFiles(String inputClass) => _inputFiles[inputClass] ?? false;

  List<_Field> _input(
    String name,
    RouteEntry route,
    String verb,
    Map<String, Object> rules,
  ) {
    _inputCount++;
    final schema = rulesToJsonSchema(rules);
    final parsed = RuleParser.parseMap(rules);
    final fields = [
      for (final field in _fields(schema, name, models: false))
        field.type == _object && _stringRules(parsed[field.key] ?? const [])
            ? _Field(
                field.key,
                const _Type('String', _asString, null),
                required: field.required,
                nullable: field.nullable,
              )
            : field,
    ];
    final form = route.formRequest;
    final attributes = form?.attributes() ?? const <String, String>{};
    final messages = form?.messages() ?? const <String, String>{};
    final serverOnly = <String>[];
    final checks = StringBuffer();
    final validators = StringBuffer();
    for (final MapEntry(key: path, value: list) in parsed.entries) {
      if (path.contains('*')) {
        serverOnly.add('`$path`');
        continue;
      }
      final skipped = <String>[];
      final entries = <String>[];
      for (final rule in list) {
        if (rule is NullableRule || rule is SometimesRule || rule is BailRule) {
          continue;
        }
        String message(String key) {
          final display = attributes[path] ?? path.replaceAll('_', ' ');
          final override =
              messages['$path.${rule.name}'] ??
              messages[rule.name] ??
              messages[key];
          return _str(
            ValidationMessages.resolve(
              key,
              locale: locale,
              attribute: display,
              parameters: rule.parameters,
              overrides: <String, String>{key: ?override},
            ),
          );
        }

        final check = _check(rule, path, message);
        if (check == null) {
          skipped.add(rule.name);
        } else {
          entries.add(check);
        }
      }
      if (skipped.isNotEmpty) {
        serverOnly.add('`$path`: ${skipped.join(', ')}');
      }
      final flags = [
        if (list.any((r) => r is NullableRule)) 'nullable: true',
        if (list.any((r) => r is SometimesRule)) 'sometimes: true',
        if (list.any((r) => r is BailRule)) 'bail: true',
      ];
      checks.write(
        '    ${_str(path)}: FieldChecks([${entries.join(', ')}]'
        '${flags.isEmpty ? '' : ', ${flags.join(', ')}'}),\n',
      );
      if (!path.contains('.')) {
        validators
          ..write(
            '  /// The first server message for `$path`, or `null` when valid:\n',
          )
          ..write(
            '  /// a `TextFormField.validator`. Pass [data] (the other fields)\n',
          )
          ..write('  /// for rules that compare fields, such as `confirmed`.\n')
          ..write(
            '  static String? validate${_pascal(path)}(Object? value, '
            '[Map<String, Object?>? data]) =>\n'
            '      rules[${_str(path)}]!.first(value, data);\n\n',
          );
      }
    }
    final files = fields.where((f) => f.type.binary).toList();
    _inputFiles[name] = files.isNotEmpty;
    final source = form == null ? 'inline rules' : '`${form.runtimeType}`';
    final out = StringBuffer()
      ..write(
        '/// Input of `$verb ${route.path}`, validated by the server with $source.\n',
      );
    if (serverOnly.isNotEmpty) {
      out.write(
        '///\n/// Checked by the server only: ${serverOnly.join('; ')}.\n',
      );
      _notes.add('${route.path}: server-only rules ${serverOnly.join('; ')}');
    }
    out
      ..write('final class $name {\n')
      ..write(
        '  const $name({${fields.map((f) => '${f.required && !f.nullable ? 'required ' : ''}this.${f.name}').join(', ')}});\n\n',
      );
    for (final field in fields) {
      out.write(
        '  final ${field.type.typeName(nullable: !(field.required && !field.nullable))} ${field.name};\n',
      );
    }
    out.write(
      '\n  /// The body (or query) sent to the server; unset fields are left out.\n',
    );
    out.write('  Map<String, Object?> toJson() => {\n');
    for (final field in fields.where((f) => !f.type.binary)) {
      final optional = !(field.required && !field.nullable);
      out.write(
        optional
            ? '        if (${field.name} != null) ${_str(field.key)}: ${field.name},\n'
            : '        ${_str(field.key)}: ${field.name},\n',
      );
    }
    out.write('      };\n\n');
    if (files.isNotEmpty) {
      out
        ..write('  /// The file parts of a multipart request.\n')
        ..write('  List<http.MultipartFile> get files => [\n');
      for (final field in files) {
        final optional = !(field.required && !field.nullable);
        out.write(
          optional ? '        ?${field.name},\n' : '        ${field.name},\n',
        );
      }
      out.write('      ];\n\n');
    }
    out
      ..write('  /// The server\'s rules that can be checked on the device.\n')
      ..write('  static const Map<String, FieldChecks> rules = {\n')
      ..write(checks)
      ..write('  };\n\n')
      ..write(
        '  /// Every message per field, as the server\'s 422 would list them\n',
      )
      ..write('  /// (empty when valid).\n')
      ..write(
        '  Map<String, List<String>> validate() => validateAll(rules, toJson());\n\n',
      )
      ..write(validators)
      ..write('}\n\n');
    _inputs.write(out);
    return fields;
  }

  /// Whether [rules] without a type rule still only accept strings (or
  /// values sent as strings): `in:` with string values, patterns, digits.
  static bool _stringRules(List<Rule> rules) => rules.any(
    (rule) => switch (rule) {
      InRule(:final values, negate: false) => values.every((v) => v is String),
      EmailRule() || UuidRule() || UlidRule() || AlphaRule() => true,
      AlphaNumRule() || AlphaDashRule() || AsciiRule() || RegexRule() => true,
      LowercaseRule() || UppercaseRule() || UrlRule() => true,
      StartsWithRule() || EndsWithRule() => true,
      DigitsRule() || DigitsBetweenRule() => true,
      _ => false,
    },
  );

  /// The `Check` expression of [rule], or `null` when only the server can
  /// check it (database lookups, dates, files, closures, ...).
  String? _check(Rule rule, String path, String Function(String key) m) {
    String pattern(String name, RegExp regex, {bool negate = false}) =>
        'Check.pattern(${_str(name)}, ${_str(regex.pattern)}, ${m(name)}'
        '${regex.isUnicode ? ', unicode: true' : ''}'
        '${regex.isCaseSensitive ? '' : ', caseSensitive: false'}'
        '${negate ? ', negate: true' : ''})';
    String sizes(String name) =>
        "{'string': ${m('$name.string')}, 'numeric': ${m('$name.numeric')}, 'array': ${m('$name.array')}}";
    return switch (rule) {
      RequiredRule() => 'Check.required(${m('required')})',
      StringRule() => "Check.type('string', ${m('string')})",
      IntegerRule() => "Check.type('integer', ${m('integer')})",
      NumericRule() => "Check.type('numeric', ${m('numeric')})",
      BooleanRule() => "Check.type('boolean', ${m('boolean')})",
      ListRule() => "Check.type('array', ${m('array')})",
      EmailRule(:final pattern) => _pattern(pattern, 'email', m),
      UuidRule(:final pattern) => _pattern(pattern, 'uuid', m),
      UlidRule(:final pattern) => _pattern(pattern, 'ulid', m),
      AlphaRule(:final pattern) => _pattern(pattern, 'alpha', m),
      AlphaNumRule(:final pattern) => _pattern(pattern, 'alpha_num', m),
      AlphaDashRule(:final pattern) => _pattern(pattern, 'alpha_dash', m),
      AsciiRule(:final pattern) => _pattern(pattern, 'ascii', m),
      RegexRule(pattern: final regex, :final negate) => pattern(
        rule.name,
        regex,
        negate: negate,
      ),
      UrlRule() => 'Check.url(${m('url')})',
      LowercaseRule() => 'Check.lowercase(${m('lowercase')})',
      UppercaseRule() => 'Check.uppercase(${m('uppercase')})',
      MinRule(:final min) => "Check.size('min', ${sizes('min')}, a: $min)",
      MaxRule(:final max) => "Check.size('max', ${sizes('max')}, a: $max)",
      BetweenRule(:final min, :final max) =>
        "Check.size('between', ${sizes('between')}, a: $min, b: $max)",
      SizeRule(:final size) => "Check.size('size', ${sizes('size')}, a: $size)",
      DigitsRule(:final length) => 'Check.digits(${m('digits')}, $length)',
      DigitsBetweenRule(:final min, :final max) =>
        'Check.digitsBetween(${m('digits_between')}, $min, $max)',
      InRule(:final values, :final negate) => _oneOf(rule, values, negate, m),
      StartsWithRule(:final prefixes) =>
        'Check.startsWith(${m('starts_with')}, [${prefixes.map(_str).join(', ')}])',
      EndsWithRule(:final suffixes) =>
        'Check.endsWith(${m('ends_with')}, [${suffixes.map(_str).join(', ')}])',
      ConfirmedRule(:final field) =>
        'Check.confirmed(${m('confirmed')}, ${_str(field ?? '${path}_confirmation')})',
      PasswordRule(
        :final min,
        :final letters,
        :final mixedCase,
        :final numbers,
        :final symbols,
      ) =>
        "Check.password({'string': ${m('string')}, 'min': ${m('min.string')}, "
            "'letters': ${m('password.letters')}, 'mixed': ${m('password.mixed')}, "
            "'numbers': ${m('password.numbers')}, 'symbols': ${m('password.symbols')}}, $min, "
            "[${[if (letters) "'letters'", if (mixedCase) "'mixed'", if (numbers) "'numbers'", if (symbols) "'symbols'"].join(', ')}])",
      _ => null,
    };
  }

  String _pattern(RegExp regex, String name, String Function(String) m) =>
      'Check.pattern(${_str(name)}, ${_str(regex.pattern)}, ${m(name)}'
      '${regex.isUnicode ? ', unicode: true' : ''}'
      '${regex.isCaseSensitive ? '' : ', caseSensitive: false'})';

  String? _oneOf(
    Rule rule,
    List<Object?> values,
    bool negate,
    String Function(String) m,
  ) {
    final literals = values.map(_literal).toList();
    if (literals.contains(null)) {
      return null;
    }
    return 'Check.oneOf(${m(rule.name)}, [${literals.join(', ')}]'
        '${negate ? ', negate: true' : ''})';
  }

  // -------------------------------------------------------------------------
  // Files
  // -------------------------------------------------------------------------

  static const String _header =
      '// GENERATED by `dartisan client:flutter`. Do not edit: regenerate instead.\n';

  String _file(StringBuffer body, {required bool importHttp}) {
    final imports = [
      if (importHttp) "import 'package:http/http.dart' as http;\n",
      "import 'runtime.dart';\n",
    ];
    final text = body.isEmpty
        ? '// Nothing declared by the routes.\n'
        : body.toString();
    return '$_header\n'
        '// ignore_for_file: unused_import\n\n'
        '${imports.join()}\n$text';
  }

  String _api() {
    final out = StringBuffer()
      ..write(_header)
      ..write('\n// ignore_for_file: unused_import\n\n')
      ..write("import 'package:http/http.dart' as http;\n\n")
      ..write("import 'inputs.dart';\n")
      ..write("import 'models.dart';\n")
      ..write("import 'runtime.dart';\n\n")
      ..write('/// Typed client of $title.\n///\n')
      ..write(
        "/// ```dart\n/// final api = $_clientClass(baseUrl: ${_str(baseUrl)});\n/// ```\n",
      )
      ..write('final class $_clientClass extends DaravelClient {\n')
      ..write(
        '  $_clientClass({\n'
        '    super.baseUrl = ${_str(baseUrl)},\n'
        '    super.httpClient,\n'
        '    super.tokens,\n'
        '    super.headers,\n'
        '  });\n\n',
      );
    final groups = _groups.keys.toList()..sort();
    for (final group in groups) {
      out.write(
        '  /// The `$group.*` routes.\n'
        '  late final ${_pascal(group)}Api $group = ${_pascal(group)}Api._(this);\n\n',
      );
    }
    out
      ..write(_root)
      ..write('}\n\n');
    for (final group in groups) {
      out
        ..write('/// The `$group.*` routes of [$_clientClass].\n')
        ..write('final class ${_pascal(group)}Api {\n')
        ..write('  ${_pascal(group)}Api._(this._client);\n\n')
        ..write('  final DaravelClient _client;\n\n')
        ..write(_groups[group])
        ..write('}\n\n');
    }
    return out.toString();
  }

  String _barrel() =>
      '$_header\n'
      '/// Typed client of $title, generated from its routes.\n'
      'library;\n\n'
      "export 'src/api.dart';\n"
      "${states.contains('bloc') ? "export 'src/blocs.dart';\n" : ''}"
      "${states.contains('cubit') ? "export 'src/cubits.dart';\n" : ''}"
      "export 'src/inputs.dart';\n"
      "export 'src/models.dart';\n"
      "${states.contains('riverpod') ? "export 'src/providers.dart';\n" : ''}"
      "${states.contains('bloc') || states.contains('cubit') ? "export 'src/remote_state.dart';\n" : ''}"
      "export 'src/runtime.dart';\n";

  String _pubspec() =>
      'name: $packageName\n'
      'description: Typed client of $title, generated by dartisan client:flutter.\n'
      'publish_to: none\n'
      'version: 1.0.0\n\n'
      'environment:\n'
      '  sdk: ^3.6.0\n\n'
      'dependencies:\n'
      '${_stateDependencies.map((d) => '  $d\n').join()}'
      '  http: ^1.2.0\n';

  /// The packages the state adapters need, as pubspec lines.
  List<String> get _stateDependencies => [
    if (states.contains('bloc') || states.contains('cubit')) 'bloc: ^9.0.0',
    if (states.contains('riverpod')) 'riverpod: ^3.0.0',
  ];
}

const String _analysisOptions = '''
analyzer:
  language:
    strict-casts: true
    strict-inference: true
    strict-raw-types: true
''';

String _toInt(String json) => '($json as num).toInt()';
String _asNum(String json) => '$json as num';
String _asBool(String json) => '$json as bool';
String _asString(String json) => '$json as String';
String _toMap(String json) => 'jsonObject($json)';
String _toDateTime(String json) => 'DateTime.parse($json as String)';
String _fromDateTime(String value, bool nullable) =>
    '$value${nullable ? '?' : ''}.toIso8601String()';

// ---------------------------------------------------------------------------
// State adapters (`--state=riverpod,bloc,cubit`)
// ---------------------------------------------------------------------------

/// The state adapters `--state` accepts.
const List<String> clientStates = ['riverpod', 'bloc', 'cubit'];

/// Files only some runs write; removed when a run no longer does.
const List<String> _optionalFiles = [
  'lib/src/remote_state.dart',
  'lib/src/providers.dart',
  'lib/src/blocs.dart',
  'lib/src/cubits.dart',
];

/// One generated client method, for the state adapters.
final class _Op {
  _Op({
    required this.group,
    required this.method,
    required this.returnType,
    required this.query,
    required this.doc,
    required this.params,
  });

  final String group;
  final String method;
  final String returnType;

  /// A GET: a cached query (providers) and `load` rather than `submit`.
  final bool query;
  final String doc;
  final List<_Param> params;

  /// The class-name stem: `UsersShow`, or `Ping` for a root method.
  String get stem => '${_pascal(group)}${_pascal(method)}';

  /// The call on the client: `users.show` or `ping`.
  String get target => group.isEmpty ? method : '$group.$method';

  /// Parameters a state adapter exposes: not the untyped `query`/`body`
  /// maps (a new map per build would never be equal, refetching forever).
  List<_Param> get typed =>
      params.where((p) => !p.type.startsWith('Map<')).toList();

  /// The client call with [value] reading each parameter (`event.id`).
  String call(String client, String Function(_Param) value) {
    final args = [
      for (final param in typed)
        param.named ? '${param.name}: ${value(param)}' : value(param),
    ];
    return '$client.$target(${args.join(', ')})';
  }
}

final class _Param {
  const _Param(
    this.type,
    this.name, {
    required this.named,
    required this.required,
  });

  /// Parses `required String name`, `int? page` or `int id`.
  factory _Param.parse(
    String source, {
    required bool named,
    bool optional = false,
  }) {
    final isRequired = source.startsWith('required ');
    final text = isRequired ? source.substring('required '.length) : source;
    final space = text.lastIndexOf(' ');
    return _Param(
      text.substring(0, space),
      text.substring(space + 1),
      named: named,
      required: named ? isRequired : !optional,
    );
  }

  final String type;
  final String name;
  final bool named;
  final bool required;
}

extension on _Generator {
  /// The imports of an adapter file covering [ops].
  String _stateImports(
    Iterable<_Op> ops, {
    required bool bloc,
    required bool riverpod,
  }) {
    final usesHttp = ops.any(
      (op) => op.typed.any((p) => p.type.startsWith('http.')),
    );
    return [
      if (bloc) "import 'package:bloc/bloc.dart';\n",
      if (usesHttp) "import 'package:http/http.dart' as http;\n",
      if (riverpod) "import 'package:riverpod/riverpod.dart';\n",
      '\n',
      "import 'api.dart';\n",
      "import 'models.dart';\n",
      if (bloc) "import 'remote_state.dart';\n",
      "import 'runtime.dart';\n",
    ].join();
  }

  String _remoteState() =>
      '${_Generator._header}\n'
      "import 'runtime.dart';\n\n"
      '/// The state of one request in a Bloc or Cubit.\n'
      'sealed class RemoteState<T> {\n'
      '  const RemoteState();\n\n'
      '  /// The last data, kept while reloading.\n'
      '  T? get dataOrNull => switch (this) {\n'
      '    RemoteData<T>(:final data) => data,\n'
      '    RemoteLoading<T>(:final previous) => previous,\n'
      '    _ => null,\n'
      '  };\n'
      '}\n\n'
      '/// Nothing requested yet.\n'
      'final class RemoteIdle<T> extends RemoteState<T> {\n'
      '  const RemoteIdle();\n'
      '}\n\n'
      '/// In flight; [previous] is the data of the last success, if any.\n'
      'final class RemoteLoading<T> extends RemoteState<T> {\n'
      '  const RemoteLoading([this.previous]);\n\n'
      '  final T? previous;\n'
      '}\n\n'
      '/// Succeeded.\n'
      'final class RemoteData<T> extends RemoteState<T> {\n'
      '  const RemoteData(this.data);\n\n'
      '  final T data;\n'
      '}\n\n'
      '/// Failed: an [ApiException] for an error response.\n'
      'final class RemoteError<T> extends RemoteState<T> {\n'
      '  const RemoteError(this.error, [this.stackTrace]);\n\n'
      '  final Object error;\n'
      '  final StackTrace? stackTrace;\n\n'
      "  /// The 422 body, for form fields: `validation?.first('email')`.\n"
      '  ValidationException? get validation => switch (error) {\n'
      '    final ValidationException e => e,\n'
      '    _ => null,\n'
      '  };\n'
      '}\n\n'
      '/// Emits loading, then the data or the error of [call].\n'
      'Future<void> runRemote<T>(\n'
      '  RemoteState<T> current,\n'
      '  void Function(RemoteState<T> state) emit,\n'
      '  Future<T> Function() call,\n'
      ') async {\n'
      '  emit(RemoteLoading<T>(current.dataOrNull));\n'
      '  try {\n'
      '    emit(RemoteData<T>(await call()));\n'
      '  } on Object catch (error, stackTrace) {\n'
      '    emit(RemoteError<T>(error, stackTrace));\n'
      '  }\n'
      '}\n';

  String _providers() {
    final client = '${_camel(packageName)}Provider';
    final out = StringBuffer()
      ..write(_Generator._header)
      ..write('\n')
      ..write(_stateImports(_queries, bloc: false, riverpod: true))
      ..write('\n')
      ..write(
        '/// The client. Override it to set the base URL and token store:\n',
      )
      ..write('/// `ProviderScope(overrides: [$client.overrideWithValue(\n')
      ..write('/// $_clientClass(baseUrl: ...))])`.\n')
      ..write('final $client = Provider<$_clientClass>((ref) {\n')
      ..write('  final client = $_clientClass();\n')
      ..write('  ref.onDispose(client.close);\n')
      ..write('  return client;\n')
      ..write('});\n\n');
    final watch = 'ref.watch($client)';
    for (final op in _queries) {
      final name = '${_camel(op.stem)}Provider';
      final params = op.typed;
      out
        ..write('/// ${op.doc}: `ref.watch($name')
        ..write(params.isEmpty ? '' : '(...)')
        ..write(')`; refresh with `ref.invalidate($name)`.\n');
      if (params.isEmpty) {
        out.write(
          'final $name = FutureProvider.autoDispose<${op.returnType}>(\n'
          '  (ref) => ${op.call(watch, (p) => p.name)},\n'
          ');\n\n',
        );
      } else if (params.length == 1) {
        final param = params.single;
        out.write(
          'final $name = FutureProvider.autoDispose\n'
          '    .family<${op.returnType}, ${_nullable(param)}>(\n'
          '      (ref, ${param.name}) => ${op.call(watch, (p) => p.name)},\n'
          '    );\n\n',
        );
      } else {
        final record =
            '({${params.map((p) => '${_nullable(p)} ${p.name}').join(', ')}})';
        out.write(
          '///\n'
          '/// The argument is a record: '
          '`$name((${params.map((p) => '${p.name}: ...').join(', ')}))`.\n'
          'final $name = FutureProvider.autoDispose\n'
          '    .family<${op.returnType}, $record>(\n'
          '      (ref, args) => ${op.call(watch, (p) => 'args.${p.name}')},\n'
          '    );\n\n',
        );
      }
    }
    return out.toString();
  }

  /// The operations with a provider: reads that return data.
  Iterable<_Op> get _queries =>
      _ops.where((op) => op.query && op.returnType != 'void');

  /// A parameter's type in a state adapter: optional ones are nullable.
  String _nullable(_Param param) => param.required || param.type.endsWith('?')
      ? param.type
      : '${param.type}?';

  String _cubits() {
    final out = StringBuffer()
      ..write(_Generator._header)
      ..write('\n')
      ..write(_stateImports(_ops, bloc: true, riverpod: false))
      ..write('\n');
    for (final op in _ops) {
      final type = op.returnType;
      final verb = op.query ? 'load' : 'submit';
      out
        ..write('/// ${op.doc}: call [$verb]; the state follows the request.\n')
        ..write(
          'final class ${op.stem}Cubit extends Cubit<RemoteState<$type>> {\n',
        )
        ..write(
          '  ${op.stem}Cubit(this._client) : super(RemoteIdle<$type>());\n\n',
        )
        ..write('  final $_clientClass _client;\n\n')
        ..write('  Future<void> $verb(${_signature(op.typed)}) =>\n')
        ..write(
          '      runRemote(state, emit, () => '
          '${op.call('_client', (p) => p.name)});\n',
        )
        ..write('}\n\n');
    }
    return out.toString();
  }

  String _blocs() {
    final out = StringBuffer()
      ..write(_Generator._header)
      ..write('\n')
      ..write(_stateImports(_ops, bloc: true, riverpod: false))
      ..write('\n');
    for (final op in _ops) {
      final type = op.returnType;
      final event = '${op.stem}Requested';
      final params = op.typed;
      out
        ..write('/// Requests ${op.doc} from [${op.stem}Bloc].\n')
        ..write('final class $event {\n')
        ..write('  const $event(${_signature(params, fields: true)});\n');
      if (params.isNotEmpty) {
        out.write('\n');
      }
      for (final param in params) {
        out.write('  final ${_nullable(param)} ${param.name};\n');
      }
      out
        ..write('}\n\n')
        ..write('/// ${op.doc}: add [$event]; the state follows the request.\n')
        ..write(
          'final class ${op.stem}Bloc extends Bloc<$event, RemoteState<$type>> {\n',
        )
        ..write(
          '  ${op.stem}Bloc(this._client) : super(RemoteIdle<$type>()) {\n',
        )
        ..write('    on<$event>(\n')
        ..write('      (event, emit) => runRemote(\n')
        ..write('        state,\n')
        ..write('        emit.call,\n')
        ..write(
          '        () => ${op.call('_client', (p) => 'event.${p.name}')},\n',
        )
        ..write('      ),\n')
        ..write('    );\n')
        ..write('  }\n\n')
        ..write('  final $_clientClass _client;\n')
        ..write('}\n\n');
    }
    return out.toString();
  }

  /// A parameter list for [params]: positional first, then named (or, with
  /// [fields], `this.` initializers).
  String _signature(List<_Param> params, {bool fields = false}) {
    String one(_Param p) =>
        fields ? 'this.${p.name}' : '${_nullable(p)} ${p.name}';
    final positional = params.where((p) => !p.named && p.required).map(one);
    final optional = params.where((p) => !p.named && !p.required).map(one);
    final named = params
        .where((p) => p.named)
        .map((p) => '${p.required ? 'required ' : ''}${one(p)}');
    return [
      ...positional,
      if (optional.isNotEmpty) '[${optional.join(', ')}]',
      if (named.isNotEmpty) '{${named.join(', ')}}',
    ].join(', ');
  }
}
