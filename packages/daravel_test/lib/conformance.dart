/// Laravel 12 conformance contracts (BLUEPRINT_V2 §11.2): fixtures taken
/// from the Laravel and Sanctum sources plus matchers, shared by the
/// framework's conformance suite and by applications that want to verify
/// their API still speaks Laravel's wire format.
///
/// ```dart
/// import 'package:daravel_test/conformance.dart';
///
/// expect(response.json, isLaravelValidationError({'email': [...]}));
/// ```
library;

export 'src/conformance/laravel_contract.dart';
export 'src/conformance/laravel_validation_messages.dart';
