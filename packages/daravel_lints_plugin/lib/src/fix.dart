import 'package:analysis_server_plugin/edit/dart/correction_producer.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/source/source_range.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_core.dart';
import 'package:analyzer_plugin/utilities/fixes/fixes.dart';
import 'package:daravel_lints/daravel_lints.dart';

/// The quick fix of a `daravel_lints` rule ([LintRule.fixFor]) in the
/// editor, with "fix all in file": the same edits `dartisan lint` would
/// make. Offered only where the rule offers a fix.
final class DaravelFix extends ResolvedCorrectionProducer {
  /// The fix of [rule]'s finding the [context] points at; [ruleIn] builds
  /// the rule run on the file, for a rule that depends on its package.
  DaravelFix(this.rule, {required super.context, this.ruleIn});

  /// The rule whose finding is fixed.
  final LintRule rule;

  /// The rule run on a file, when it depends on the file's package
  /// (`string_column_name` and the models it reads).
  final LintRule Function(File file)? ruleIn;

  // The edits taken so far for one "fix all in file" (the analysis server
  // runs one producer per finding on one builder): an edit two findings
  // share (one `const`, one import) is made once, so the server never sees
  // it twice.
  static final Expando<LintFixMerger> _merging = Expando();

  String _message = '';

  @override
  CorrectionApplicability get applicability =>
      CorrectionApplicability.acrossSingleFile;

  @override
  FixKind get fixKind => FixKind('daravel.fix.${rule.name}', 50, '{0}');

  @override
  List<String> get fixArguments => [_message];

  @override
  FixKind get multiFixKind => FixKind(
    'daravel.fix.${rule.name}.multi',
    50,
    'Fix all ${rule.name} findings in file',
  );

  @override
  Future<void> compute(ChangeBuilder builder) async {
    final offset = diagnosticOffset;
    final length = diagnosticLength;
    if (offset == null || length == null) {
      return;
    }
    final unit = this.unit;
    final rule = ruleIn?.call(unitResult.file) ?? this.rule;
    AstNode? found;
    rule.check(unit, (node, _) {
      if (node.offset == offset && node.length == length) {
        found ??= node;
      }
    });
    final node = found;
    final fix = node == null ? null : rule.fixFor(unit, node);
    if (fix == null) {
      return;
    }
    var edits = fix.edits;
    if (applyingBulkFixes) {
      final merger = _merging[builder] ??= LintFixMerger();
      final added = merger.add(fix);
      if (added == null) {
        return;
      }
      edits = added;
    }
    _message = fix.message;
    await builder.addDartFileEdit(file, (builder) {
      for (final edit in edits) {
        builder.addSimpleReplacement(
          SourceRange(edit.offset, edit.length),
          // The file's own line endings (an added import ends a line).
          edit.replacement.replaceAll('\n', builder.eol),
        );
      }
    });
  }
}
