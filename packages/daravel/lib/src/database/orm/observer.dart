import 'dart:async';

import 'model.dart';

/// Lifecycle events a model fires (Laravel parity).
enum ModelEvent {
  retrieved,
  creating,
  created,
  updating,
  updated,
  saving,
  saved,
  deleting,
  deleted,
  restoring,
  restored,
  forceDeleting,
  forceDeleted,
}

/// Observes a model's lifecycle. Return `false` from a `*ing` hook to cancel
/// the operation (`creating`, `updating`, `saving`, `deleting`, `restoring`).
abstract class ModelObserver<T extends Model> {
  const ModelObserver();

  FutureOr<bool?> retrieved(T model) => null;
  FutureOr<bool?> creating(T model) => null;
  FutureOr<bool?> created(T model) => null;
  FutureOr<bool?> updating(T model) => null;
  FutureOr<bool?> updated(T model) => null;
  FutureOr<bool?> saving(T model) => null;
  FutureOr<bool?> saved(T model) => null;
  FutureOr<bool?> deleting(T model) => null;
  FutureOr<bool?> deleted(T model) => null;
  FutureOr<bool?> restoring(T model) => null;
  FutureOr<bool?> restored(T model) => null;
  FutureOr<bool?> forceDeleting(T model) => null;
  FutureOr<bool?> forceDeleted(T model) => null;

  /// Dispatches [event] to the matching hook.
  FutureOr<bool?> handle(ModelEvent event, T model) => switch (event) {
    .retrieved => retrieved(model),
    .creating => creating(model),
    .created => created(model),
    .updating => updating(model),
    .updated => updated(model),
    .saving => saving(model),
    .saved => saved(model),
    .deleting => deleting(model),
    .deleted => deleted(model),
    .restoring => restoring(model),
    .restored => restored(model),
    .forceDeleting => forceDeleting(model),
    .forceDeleted => forceDeleted(model),
  };
}
