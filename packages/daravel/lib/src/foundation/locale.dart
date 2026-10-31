import 'container.dart';

/// The application's keyed translation lines, for the modules below
/// `translation` (validation messages, paginator labels).
abstract interface class TranslationLines {
  /// The line for [key] in [locale] (the current one by default), or `null`;
  /// with [fallback] also in the fallback locale.
  String? line(String key, {String? locale, bool fallback = true});
}

/// [TranslationLines.line] of the active application; `null` outside one.
String? translationLine(String key, {String? locale, bool fallback = true}) =>
    Container.currentOrNull?.tryMake<TranslationLines>()?.line(
      key,
      locale: locale,
      fallback: fallback,
    );

final class _ActiveLocale {
  _ActiveLocale(this.value);
  final String value;
}

/// Per isolate, like the container root.
final _ApplicationLocale _application = _ApplicationLocale();

final class _ApplicationLocale {
  String value = 'en';
}

Scope? _scope() {
  try {
    return Container.current.currentScope;
  } on StateError {
    return null;
  }
}

/// The locale of the current request, job or command: the one set with
/// [setCurrentLocale] in this scope, else the application's (`APP_LOCALE`).
/// Translations and validation messages follow it.
String currentLocale() =>
    _scope()?.get<_ActiveLocale>()?.value ?? _application.value;

/// Sets the locale of the current scope (Laravel's `App::setLocale`), so
/// concurrent requests never see each other's; outside any scope, the
/// application's.
void setCurrentLocale(String locale) {
  final scope = _scope();
  if (scope != null) {
    scope.put<_ActiveLocale>(_ActiveLocale(locale));
  } else {
    _application.value = locale;
  }
}

/// Sets the application locale (`APP_LOCALE`, at boot).
void setApplicationLocale(String locale) => _application.value = locale;
