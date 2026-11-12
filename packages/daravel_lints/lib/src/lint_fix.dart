/// The fixes a lint rule offers for its findings, as plain text edits: the
/// analysis server plugin and `dartisan lint --fix` apply the same ones.
library;

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

/// One text edit: [length] characters at [offset] replaced by
/// [replacement].
final class LintEdit {
  /// An edit of the source a finding was made in.
  const LintEdit(this.offset, this.length, this.replacement);

  /// Where the edit starts.
  final int offset;

  /// How many characters it replaces (0 inserts).
  final int length;

  /// The text put there.
  final String replacement;

  @override
  bool operator ==(Object other) =>
      other is LintEdit &&
      other.offset == offset &&
      other.length == length &&
      other.replacement == replacement;

  @override
  int get hashCode => Object.hash(offset, length, replacement);

  @override
  String toString() => 'LintEdit($offset, $length, $replacement)';
}

/// A fix for one finding: [message], the editor's label ("Write as
/// Rules.required().email()"), and the [edits] that apply it, which never
/// overlap.
final class LintFix {
  /// A fix made of [edits].
  const LintFix(this.message, this.edits);

  /// What the fix does, for a person.
  final String message;

  /// The edits, in any order.
  final List<LintEdit> edits;

  /// [source] with the [edits] applied.
  String apply(String source) {
    final sorted = [...edits]..sort((a, b) => b.offset.compareTo(a.offset));
    var result = source;
    for (final edit in sorted) {
      result = result.replaceRange(
        edit.offset,
        edit.offset + edit.length,
        edit.replacement,
      );
    }
    return result;
  }
}

/// Fixes of several findings in one file applied together ("fix all in
/// file", `dartisan lint --fix`). An edit two fixes share (the `const`
/// both remove, the import both add) is made once; a fix whose edits
/// overlap an edit already taken is left out, to be offered again once
/// the others are applied.
final class LintFixMerger {
  final List<LintEdit> _taken = [];

  /// The edits taken so far, in the order they were added.
  List<LintEdit> get edits => List.unmodifiable(_taken);

  /// Takes [fix]: returns the edits it adds (the ones not already taken),
  /// or `null`, taking nothing, when one of them overlaps a taken edit.
  List<LintEdit>? add(LintFix fix) {
    final added = <LintEdit>[];
    for (final edit in fix.edits) {
      if (_taken.contains(edit) || added.contains(edit)) {
        continue;
      }
      if ([..._taken, ...added].any((other) => _overlap(edit, other))) {
        return null;
      }
      added.add(edit);
    }
    _taken.addAll(added);
    return added;
  }

  /// Whether [a] and [b] touch the same text, or both insert at one offset
  /// (whose order would be ambiguous).
  static bool _overlap(LintEdit a, LintEdit b) {
    if (a.length == 0 && b.length == 0) {
      return a.offset == b.offset;
    }
    final aEnd = a.offset + a.length;
    final bEnd = b.offset + b.length;
    if (a.length == 0) {
      return b.offset < a.offset && a.offset < bEnd;
    }
    if (b.length == 0) {
      return a.offset < b.offset && b.offset < aEnd;
    }
    return a.offset < bEnd && b.offset < aEnd;
  }
}

/// How code in [unit] can name a member of `package:daravel/daravel.dart`
/// ([name], such as `Rules`): with the prefix it is imported under (`d.`),
/// without one, through an import added by [addImport]; or `null` when a
/// `show` that leaves it out, or a `hide` that names it, keeps it hidden
/// (a fix is then not offered).
({String prefix, LintEdit? addImport})? daravelName(
  CompilationUnit unit,
  String name,
) {
  final imports = [
    for (final directive in unit.directives)
      if (directive is ImportDirective &&
          directive.uri.stringValue == 'package:daravel/daravel.dart')
        directive,
  ];
  bool visible(ImportDirective import) => import.combinators.every(
    (c) => switch (c) {
      ShowCombinator(:final shownNames) => shownNames.any(
        (n) => n.name == name,
      ),
      HideCombinator(:final hiddenNames) => !hiddenNames.any(
        (n) => n.name == name,
      ),
    },
  );
  // An import without a prefix first: the plainest way to write it.
  for (final import in [
    ...imports.where((i) => i.prefix == null),
    ...imports.where((i) => i.prefix != null),
  ]) {
    if (visible(import)) {
      final prefix = import.prefix;
      return (prefix: prefix == null ? '' : '${prefix.name}.', addImport: null);
    }
  }
  if (imports.isNotEmpty) {
    return null;
  }
  final directives = unit.directives.whereType<UriBasedDirective>().toList();
  final at = directives.isEmpty ? 0 : directives.last.end;
  return (
    prefix: '',
    addImport: LintEdit(
      at,
      0,
      directives.isEmpty
          ? "import 'package:daravel/daravel.dart';\n\n"
          : "\nimport 'package:daravel/daravel.dart';",
    ),
  );
}

/// When [expression] sits in a constant context, the edit that makes it
/// leave it: removing the `const` of the nearest enclosing list, set or map
/// literal, when that literal is not itself constant for another reason
/// (a `const` variable, a `const` constructor call, an annotation, a
/// default value). Returns an empty list outside a constant context and
/// `null` when the context cannot be left by one edit.
List<LintEdit>? leaveConstantContext(Expression expression) {
  if (!expression.inConstantContext) {
    return const [];
  }
  TypedLiteral? literal;
  for (AstNode? node = expression.parent; node != null; node = node.parent) {
    if (node is TypedLiteral && node.constKeyword != null) {
      literal = node;
      break;
    }
    if (_makesConstant(node)) {
      return null;
    }
  }
  if (literal == null) {
    return null;
  }
  for (AstNode? node = literal.parent; node != null; node = node.parent) {
    if (_makesConstant(node) ||
        (node is TypedLiteral && node.constKeyword != null)) {
      return null;
    }
    if (node is Statement || node is Declaration) {
      break;
    }
  }
  final keyword = literal.constKeyword!;
  final Token? next = keyword.next;
  return [
    LintEdit(
      keyword.offset,
      (next?.offset ?? keyword.end) - keyword.offset,
      '',
    ),
  ];
}

bool _makesConstant(AstNode node) => switch (node) {
  InstanceCreationExpression(:final keyword) =>
    keyword?.keyword == Keyword.CONST,
  VariableDeclarationList(:final isConst) => isConst,
  // A literal in a parameter is its default value, which is constant.
  Annotation() || FormalParameter() => true,
  _ => false,
};
