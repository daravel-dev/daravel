import 'dart:async';

import '../http/request.dart';

/// Controller contract for `Router.apiResource` (index, store, show, update,
/// destroy). Implement the actions you need; the router only registers the
/// ones selected with `only`/`except`.
abstract interface class ResourceController {
  FutureOr<Object?> index(Request request);
  FutureOr<Object?> store(Request request);
  FutureOr<Object?> show(Request request);
  FutureOr<Object?> update(Request request);
  FutureOr<Object?> destroy(Request request);
}

/// Adds the HTML form actions used by `Router.resource` (create, edit).
abstract interface class WebResourceController implements ResourceController {
  FutureOr<Object?> create(Request request);
  FutureOr<Object?> edit(Request request);
}

/// Minimal English singularization used for resource parameter names
/// (`posts` → `post`, `categories` → `category`, `people` → `people`).
String singularize(String word) {
  if (word.endsWith('ies') && word.length > 3) {
    return '${word.substring(0, word.length - 3)}y';
  }
  if (word.endsWith('ses') ||
      word.endsWith('xes') ||
      word.endsWith('ches') ||
      word.endsWith('shes')) {
    return word.substring(0, word.length - 2);
  }
  if (word.endsWith('us') || word.endsWith('ss') || word.endsWith('is')) {
    return word;
  }
  if (word.endsWith('s') && word.length > 1) {
    return word.substring(0, word.length - 1);
  }
  return word;
}
