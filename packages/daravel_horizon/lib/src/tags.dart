import 'package:daravel/daravel.dart';

/// Monitoring tags for `Job.tags`, as Laravel Horizon writes them.
abstract final class HorizonTags {
  /// `User:42` for a loaded model or a `ModelRef` (what `make:job --model`
  /// generates): the singular of the model's table in StudlyCase, a colon
  /// and its key. Payloads hold bare ids, so Daravel cannot find models in
  /// a job by itself; list them in `tags`.
  static String model(Object modelOrRef) {
    final (String table, Object? key) = switch (modelOrRef) {
      final Model model => (model.table, model.key),
      final ModelRef<Model> ref => (ref.definition().table, ref.id),
      _ => throw ArgumentError.value(
        modelOrRef,
        'modelOrRef',
        'Expected a Model or a ModelRef',
      ),
    };
    return '${Str.studly(Str.singular(table))}:$key';
  }
}
