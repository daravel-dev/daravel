import 'package:daravel/daravel.dart';

/// A row that failed validation (Laravel Excel's `Failure`).
final class Failure {
  const Failure(
    this.row,
    this.attribute,
    this.errors, [
    this.values = const {},
  ]);

  /// The row's number in the sheet.
  final int row;
  final String attribute;
  final List<String> errors;

  /// The row's cells.
  final Map<String, Object?> values;

  /// `There was an error on row 2. The email field is required.`, one per
  /// error.
  List<String> toList() => [
    for (final message in errors) 'There was an error on row $row. $message',
  ];

  Map<String, Object?> toJson() => {
    'row': row,
    'attribute': attribute,
    'errors': errors,
    'values': values,
  };
}

/// Rows of an import failed validation; nothing was saved, since the
/// import runs in a transaction. A 422 whose errors are keyed
/// `<row>.<attribute>`, as Laravel Excel's exception renders.
final class ExcelValidationException extends ValidationException {
  ExcelValidationException(this.failures)
    : super({
        for (final failure in failures)
          '${failure.row}.${failure.attribute}': failure.errors,
      });

  final List<Failure> failures;
}
