import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:daravel_lints/daravel_lints.dart';

/// The model index `string_column_name` needs for one file in the editor:
/// the models the file refers to, as the analysis server resolved them,
/// that are declared under `lib/app/models` of the file's package (the
/// folder that holds its `pubspec.yaml`), as `dartisan lint` reads them.
///
/// Only those model files are read, through the analysis server's
/// resource provider (unsaved edits count), and each is parsed once per
/// modification stamp; the package root of each folder is looked up once.
/// So analyzing a file costs a walk of its AST and one stamp per model it
/// refers to, however many models the project has.
///
/// A model the file does not import is not resolved, so it is not
/// reported here; the file does not compile anyway.
final class ModelIndexCache {
  final Map<String, Folder?> _roots = {};
  final Map<String, (int, ModelColumnIndex)> _byFile = {};
  int _parses = 0;

  /// How many model files were parsed so far (one per file and stamp).
  int get parses => _parses;

  /// The index of the models [unit] (resolved, of [file]) refers to.
  ModelColumnIndex indexFor(File file, CompilationUnit unit) {
    final root = _rootOf(file.parent);
    if (root == null) {
      return ModelColumnIndex(const {});
    }
    final context = file.provider.pathContext;
    final models = context.join(root.path, 'lib', 'app', 'models');
    final paths = <String>{};
    unit.accept(
      _References((path) {
        if (context.isWithin(models, path)) {
          paths.add(path);
        }
      }),
    );
    return indexOfFiles([
      for (final path in paths) file.provider.getFile(path),
    ]);
  }

  /// The index of the model [files]: each parsed once per modification
  /// stamp; one that cannot be read counts as no model.
  ModelColumnIndex indexOfFiles(Iterable<File> files) =>
      ModelColumnIndex.merge([for (final file in files) ?_indexOf(file)]);

  ModelColumnIndex? _indexOf(File file) {
    try {
      final stamp = file.modificationStamp;
      final cached = _byFile[file.path];
      if (cached != null && cached.$1 == stamp) {
        return cached.$2;
      }
      _parses++;
      final index = ModelColumnIndex.ofSource(file.readAsStringSync());
      _byFile[file.path] = (stamp, index);
      return index;
    } on FileSystemException {
      _byFile.remove(file.path);
      return null;
    }
  }

  Folder? _rootOf(Folder start) {
    if (_roots.containsKey(start.path)) {
      return _roots[start.path];
    }
    final Folder? root;
    if (start.getFile('pubspec.yaml').exists) {
      root = start;
    } else if (start.isRoot) {
      root = null;
    } else {
      root = _rootOf(start.parent);
    }
    return _roots[start.path] = root;
  }
}

/// The files declaring the classes a unit names.
final class _References extends RecursiveAstVisitor<void> {
  _References(this.found);

  final void Function(String path) found;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.element case final InterfaceElement element) {
      found(element.firstFragment.libraryFragment.source.fullName);
    }
  }
}
