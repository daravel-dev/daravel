import 'package:analyzer/file_system/file_system.dart';
import 'package:daravel_lints/daravel_lints.dart';

/// The model index of each package (`lib/app/models` under the folder that
/// holds its `pubspec.yaml`), for `string_column_name` in the editor. The
/// files are read through the analysis server's resource provider, so an
/// unsaved change to a model counts; an index is rebuilt when a model file
/// is added, removed or changed (its modification stamp), and kept
/// otherwise.
final class ModelIndexCache {
  final Map<String, (String, ModelColumnIndex)> _byRoot = {};

  /// The index of the package [file] belongs to; empty outside a package,
  /// without models, or when a model cannot be read.
  ModelColumnIndex indexFor(File file) {
    final root = _packageRoot(file.parent);
    if (root == null) {
      return ModelColumnIndex(const {});
    }
    try {
      final models = root.getFolder('lib').getFolder('app').getFolder('models');
      final files = models.exists ? _dartFiles(models) : <File>[];
      files.sort((a, b) => a.path.compareTo(b.path));
      final stamp = [for (final f in files) '${f.path}:${f.modificationStamp}']
          .join('\n');
      final cached = _byRoot[root.path];
      if (cached != null && cached.$1 == stamp) {
        return cached.$2;
      }
      final index = ModelColumnIndex.ofSources([
        for (final f in files) f.readAsStringSync(),
      ]);
      _byRoot[root.path] = (stamp, index);
      return index;
    } on FileSystemException {
      return ModelColumnIndex(const {});
    }
  }

  static Folder? _packageRoot(Folder start) {
    for (var folder = start; ; folder = folder.parent) {
      if (folder.getFile('pubspec.yaml').exists) {
        return folder;
      }
      if (folder.isRoot) {
        return null;
      }
    }
  }

  static List<File> _dartFiles(Folder folder) => [
    for (final child in folder.getChildren())
      if (child is Folder)
        ..._dartFiles(child)
      else if (child is File && child.path.endsWith('.dart'))
        child,
  ];
}
