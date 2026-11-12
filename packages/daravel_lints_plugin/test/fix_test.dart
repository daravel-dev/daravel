// test_reflective_loader runs the methods named test_..., so they cannot be
// lowerCamelCase.
// ignore_for_file: non_constant_identifier_names

import 'package:analysis_server_plugin/edit/dart/correction_producer.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_core.dart';
import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:daravel_lints/daravel_lints.dart';
import 'package:daravel_lints_plugin/daravel_lints_plugin.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

/// The quick fix of `string_validation_rule` in the editor (W9.8): the
/// edits of `LintRule.fixFor`, one finding at a time or all in the file.
void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(StringValidationRuleFixTest);
  });
}

@reflectiveTest
class StringValidationRuleFixTest extends AnalysisRuleTest {
  static const _source = '''
import 'dart:async';

class Request {
  Future<void> validate(Map<String, Object> rules) async {}
}

Future<void> f(Request request) =>
    request.validate(const {'a': 'required|email', 'b': 'max:5'});
''';

  @override
  void setUp() {
    rule = DaravelAnalysisRule(const StringValidationRule());
    super.setUp();
  }

  String get _appFile => '$testPackageRootPath/lib/app/controller.dart';

  Future<(ResolvedUnitResult, ResolvedLibraryResult, List<Diagnostic>)>
  _resolve() async {
    newFile(_appFile, _source);
    final unit = await resolveFile(_appFile);
    final library = await unit.session.getResolvedLibrary(
      unit.path,
    ) as ResolvedLibraryResult;
    final found = [
      for (final d in unit.diagnostics)
        if (d.diagnosticCode.lowerCaseName == 'string_validation_rule') d,
    ];
    return (unit, library, found);
  }

  DaravelFix _producer(
    ResolvedUnitResult unit,
    ResolvedLibraryResult library,
    Diagnostic diagnostic, {
    bool bulk = false,
  }) => DaravelFix(
    const StringValidationRule(),
    context: CorrectionProducerContext.createResolved(
      libraryResult: library,
      unitResult: unit,
      diagnostic: diagnostic,
      applyingBulkFixes: bulk,
      selectionOffset: diagnostic.offset,
      selectionLength: diagnostic.length,
    ),
  );

  String _applied(ChangeBuilder builder) => SourceEdit.applySequence(
    normalizeSource(_source),
    builder.sourceChange.edits.single.edits,
  );

  Future<void> test_one_finding() async {
    final (unit, library, found) = await _resolve();
    expect(found, hasLength(2));
    final producer = _producer(unit, library, found.first);
    final builder = ChangeBuilder(session: unit.session);
    await producer.compute(builder);
    expect(producer.fixArguments, [
      'Write as Rules.required().email() (removes const)',
    ]);
    expect(producer.canBeAppliedAcrossSingleFile, isTrue);
    expect(
      _applied(builder),
      normalizeSource('''
import 'dart:async';
import 'package:daravel/daravel.dart';

class Request {
  Future<void> validate(Map<String, Object> rules) async {}
}

Future<void> f(Request request) =>
    request.validate({'a': Rules.required().email(), 'b': 'max:5'});
'''),
    );
  }

  Future<void> test_all_in_file_shares_the_const_and_the_import() async {
    final (unit, library, found) = await _resolve();
    final builder = ChangeBuilder(session: unit.session);
    // As the analysis server runs "fix all in file": one producer per
    // finding, one builder.
    for (final diagnostic in found) {
      await _producer(unit, library, diagnostic, bulk: true).compute(builder);
    }
    expect(
      _applied(builder),
      normalizeSource('''
import 'dart:async';
import 'package:daravel/daravel.dart';

class Request {
  Future<void> validate(Map<String, Object> rules) async {}
}

Future<void> f(Request request) =>
    request.validate({'a': Rules.required().email(), 'b': Rules.max(5)});
'''),
    );
  }

  Future<void> test_a_rule_without_a_fix_offers_none() async {
    final (unit, library, found) = await _resolve();
    final producer = DaravelFix(
      const NoPrintInApp(),
      context: CorrectionProducerContext.createResolved(
        libraryResult: library,
        unitResult: unit,
        diagnostic: found.first,
        selectionOffset: found.first.offset,
        selectionLength: found.first.length,
      ),
    );
    final builder = ChangeBuilder(session: unit.session);
    await producer.compute(builder);
    expect(builder.sourceChange.edits, isEmpty);
  }
}
