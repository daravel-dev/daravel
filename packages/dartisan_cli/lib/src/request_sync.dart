/// What `request:sync` reads from a form request file and writes back: the
/// typed input of a `FormRequest<Input>` (wave 9, W9.5), one getter per
/// `static const x = Field<T>('key')` of the request class.
library;

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import 'generator.dart';
import 'region_format.dart';

/// One `Field` of a request: its constant [name], its value [type] and its
/// input [key].
typedef RequestField = ({String name, String type, String key});

/// A form request file as `request:sync` reads it.
final class RequestSource {
  /// What `request:sync` reads from a request file.
  const RequestSource({
    required this.className,
    required this.inputType,
    required this.fields,
  });

  /// `final class X extends FormRequest<XInput>` and its `Field` constants
  /// (regex-based; the layout `make:request` writes is assumed); null when
  /// the file has no typed form request.
  static RequestSource? parse(String source) {
    final head = RegExp(r'class\s+(\w+)\s+extends\s+FormRequest<(\w+)>')
        .firstMatch(source);
    if (head == null) {
      return null;
    }
    return RequestSource(
      className: head.group(1)!,
      inputType: head.group(2)!,
      fields: [
        for (final m in _field.allMatches(source))
          (name: m.group(1)!, type: m.group(2)!.trim(), key: m.group(3)!),
      ],
    );
  }

  static final RegExp _field = RegExp(
    r"static\s+const\s+(\w+)\s*=\s*Field<(.+?)>\(\s*'([^']+)'\s*\)",
  );

  /// The request class.
  final String className;

  /// The input type named in `FormRequest<...>`.
  final String inputType;

  /// The `Field` constants, in source order.
  final List<RequestField> fields;
}

const String _inputStart = '// <dartisan:input>';
const String _inputEnd = '// </dartisan:input>';

/// The `<dartisan:input>` region of [request]: its input type with one
/// getter per field, and `typed`, every field by its input key (left out
/// when a field is itself named `typed`). Laid out by [formatter] (the
/// default `dart format` settings when null), so a synced file stays
/// format-clean; written as generated when it cannot be formatted.
String inputRegion(RequestSource request, {RegionFormatter? formatter}) {
  String key(String k) =>
      "'${k.replaceAll(r'\', r'\\').replaceAll(r'$', r'\$')}'";
  final code = [
    _inputStart,
    '/// The validated input of [${request.className}], one getter per `Field`',
    '/// (written by `dartisan request:sync`; edit the fields, not this).',
    'extension type const ${request.inputType}(ValidatedData _data) '
        'implements ValidatedData {',
    for (final f in request.fields)
      '  ${f.type} get ${f.name} => '
          '_data.field(${request.className}.${f.name});',
    if (!_hidesTyped(request)) ...[
      '',
      '  /// Every field by its input key, as its declared type: the values '
          'are',
      "  /// converted (`'4'` is `4` for a `Field<int>`), unlike the raw map "
          'of',
      '  /// [ValidatedData]. `expectFormRequestTyped` reads every field with '
          'it.',
      '  Map<String, Object?> get typed => {'
          '${[for (final f in request.fields) '${key(f.key)}: ${f.name}'].join(', ')}'
          '};',
    ],
    '}',
    _inputEnd,
  ].join('\n');
  return (formatter ?? RegionFormatter()).topLevel(code);
}

bool _hidesTyped(RequestSource request) =>
    request.fields.any((f) => f.name == 'typed');

/// What `request:sync` makes of one request file: the new [source] (null
/// when the file has no typed request or declares its input type by hand)
/// and a [note] saying why.
typedef RequestSync = ({String? source, String? note});

/// [source] with its `<dartisan:input>` region written for its fields:
/// replaced when present, appended at the end otherwise (an extension
/// type is a top-level declaration).
RequestSync syncRequestSource(String source, {RegionFormatter? formatter}) {
  final request = RequestSource.parse(source);
  if (request == null) {
    return (source: null, note: 'no `extends FormRequest<Input>`; skipped');
  }
  final region = inputRegion(request, formatter: formatter);
  final note = _hidesTyped(request)
      ? 'a field is named `typed`, so ${request.inputType} has no `typed` '
            'map; pass your own read: to expectFormRequestTyped'
      : null;
  final start = source.indexOf(_inputStart);
  final end = source.indexOf(_inputEnd);
  if (start != -1 && end > start) {
    return (
      source:
          '${source.substring(0, start)}$region'
          '${source.substring(end + _inputEnd.length)}',
      note: note,
    );
  }
  if (RegExp('extension\\s+type\\s+(const\\s+)?${request.inputType}\\b')
      .hasMatch(source)) {
    return (
      source: null,
      note:
          '${request.inputType} is declared by hand (no '
          '$_inputStart region); left as it is',
    );
  }
  final base = source.endsWith('\n') ? source : '$source\n';
  return (source: '$base\n$region\n', note: note);
}

/// `request:sync [Request] [--check]`: writes the typed input of each form
/// request in `lib/app/http/requests` from its `Field` constants. With
/// `--check` nothing is written, and the exit code is 1 when a region is
/// out of date (for CI).
final class RequestSyncCommand extends Command<int> {
  /// The `dartisan request:sync` command.
  RequestSyncCommand() {
    argParser.addFlag(
      'check',
      negatable: false,
      help: 'Write nothing; exit 1 when an input type is out of date.',
    );
  }

  @override
  String get name => 'request:sync';

  @override
  String get description => '''
Write the typed input of form requests from their Field constants.

Only sources are read and written: the global dartisan runs it in the
project's dartisan_cli without compiling the application, so it works
while a request names an input type that does not exist yet. Without the
global dartisan, `dart run dartisan_cli:dartisan request:sync` from the
project does the same; `dart run bin/dartisan.dart request:sync` compiles
the application first. (model:sync does not compile it either: it reads
the schema through a connection from the environment.)''';

  @override
  Future<int> run() async {
    final paths = ProjectPaths.locate();
    final dir = Directory(paths.requests);
    if (!dir.existsSync()) {
      stdout.writeln('No form requests found in lib/app/http/requests.');
      return 0;
    }
    final only = argResults!.rest.isEmpty
        ? null
        : Naming.snake(argResults!.rest.first);
    final check = argResults!['check'] as bool;
    // The project's language version and page width, as dart format.
    final formatter = RegionFormatter.forProject(paths.root);
    var stale = 0;
    for (final file in dir.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.dart'),
    )) {
      if (only != null && p.basenameWithoutExtension(file.path) != only) {
        continue;
      }
      final name = p.basename(file.path);
      final source = file.readAsStringSync();
      final sync = syncRequestSource(source, formatter: formatter);
      final updated = sync.source;
      if (updated == null) {
        if (sync.note != null && RequestSource.parse(source) != null) {
          stdout.writeln('$name: ${sync.note}.');
        }
        continue;
      }
      if (updated == source) {
        stdout.writeln('$name: up to date.');
      } else if (check) {
        stale++;
        stdout.writeln('$name: out of date; run dartisan request:sync.');
      } else {
        file.writeAsStringSync(updated);
        stdout.writeln('$name: input type written.');
      }
      if (sync.note != null) {
        stdout.writeln('$name: ${sync.note}.');
      }
    }
    return stale == 0 ? 0 : 1;
  }
}
