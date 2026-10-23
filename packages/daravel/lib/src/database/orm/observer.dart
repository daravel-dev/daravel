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
    ModelEvent.retrieved => retrieved(model),
    ModelEvent.creating => creating(model),
    ModelEvent.created => created(model),
    ModelEvent.updating => updating(model),
    ModelEvent.updated => updated(model),
    ModelEvent.saving => saving(model),
    ModelEvent.saved => saved(model),
    ModelEvent.deleting => deleting(model),
    ModelEvent.deleted => deleted(model),
    ModelEvent.restoring => restoring(model),
    ModelEvent.restored => restored(model),
    ModelEvent.forceDeleting => forceDeleting(model),
    ModelEvent.forceDeleted => forceDeleted(model),
  };
}
