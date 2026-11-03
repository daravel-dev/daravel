import 'dart:async';

import 'model.dart';

/// Lifecycle events a model fires (Laravel parity).
enum ModelEvent {
  /// After a model is read from the database.
  retrieved,

  /// Before a new model is inserted; `false` cancels it.
  creating,

  /// After a new model is inserted.
  created,

  /// Before an existing model is updated; `false` cancels it.
  updating,

  /// After an existing model is updated.
  updated,

  /// Before any save, insert or update; `false` cancels it.
  saving,

  /// After any save.
  saved,

  /// Before a model is deleted (or soft deleted); `false` cancels it.
  deleting,

  /// After a model is deleted.
  deleted,

  /// Before a soft deleted model is restored; `false` cancels it.
  restoring,

  /// After a soft deleted model is restored.
  restored,

  /// Before a model is deleted for good; `false` cancels it.
  forceDeleting,

  /// After a model is deleted for good.
  forceDeleted,
}

/// Observes a model's lifecycle. Return `false` from a `*ing` hook to cancel
/// the operation (`creating`, `updating`, `saving`, `deleting`, `restoring`).
abstract class ModelObserver<T extends Model> {
  /// Observers are usually const; override only the events you need.
  const ModelObserver();

  /// Called after [model] is read from the database.
  FutureOr<bool?> retrieved(T model) => null;

  /// Called before [model] is inserted; return `false` to cancel.
  FutureOr<bool?> creating(T model) => null;

  /// Called after [model] is inserted.
  FutureOr<bool?> created(T model) => null;

  /// Called before [model] is updated; return `false` to cancel.
  FutureOr<bool?> updating(T model) => null;

  /// Called after [model] is updated.
  FutureOr<bool?> updated(T model) => null;

  /// Called before [model] is saved; return `false` to cancel.
  FutureOr<bool?> saving(T model) => null;

  /// Called after [model] is saved.
  FutureOr<bool?> saved(T model) => null;

  /// Called before [model] is deleted; return `false` to cancel.
  FutureOr<bool?> deleting(T model) => null;

  /// Called after [model] is deleted.
  FutureOr<bool?> deleted(T model) => null;

  /// Called before [model] is restored; return `false` to cancel.
  FutureOr<bool?> restoring(T model) => null;

  /// Called after [model] is restored.
  FutureOr<bool?> restored(T model) => null;

  /// Called before [model] is deleted for good; return `false` to cancel.
  FutureOr<bool?> forceDeleting(T model) => null;

  /// Called after [model] is deleted for good.
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
