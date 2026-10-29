// The English messages are Laravel's (laravel/framework,
// lang/en/validation.php), Copyright (c) Taylor Otwell, MIT License:
// see THIRD_PARTY_NOTICES.md.

import '../foundation/config.dart';

/// Default validation messages (Laravel `lang/en/validation.php` parity)
/// with an Indonesian translation as the second bundled locale.
abstract final class ValidationMessages {
  static const Map<String, Map<String, String>> translations = {
    'en': {
      'required': 'The :attribute field is required.',
      'present': 'The :attribute field must be present.',
      'filled': 'The :attribute field must have a value.',
      'prohibited': 'The :attribute field is prohibited.',
      'required_if': 'The :attribute field is required when :other is :value.',
      'required_unless':
          'The :attribute field is required unless :other is in :values.',
      'required_with':
          'The :attribute field is required when :values is present.',
      'required_without':
          'The :attribute field is required when :values is not present.',
      'string': 'The :attribute field must be a string.',
      'integer': 'The :attribute field must be an integer.',
      'numeric': 'The :attribute field must be a number.',
      'boolean': 'The :attribute field must be true or false.',
      'array': 'The :attribute field must be an array.',
      'map': 'The :attribute field must be an object.',
      'email': 'The :attribute field must be a valid email address.',
      'url': 'The :attribute field must be a valid URL.',
      'uuid': 'The :attribute field must be a valid UUID.',
      'ulid': 'The :attribute field must be a valid ULID.',
      'ip': 'The :attribute field must be a valid IP address.',
      'ipv4': 'The :attribute field must be a valid IPv4 address.',
      'ipv6': 'The :attribute field must be a valid IPv6 address.',
      'json': 'The :attribute field must be a valid JSON string.',
      'alpha': 'The :attribute field must only contain letters.',
      'alpha_num':
          'The :attribute field must only contain letters and numbers.',
      'alpha_dash': 'The :attribute field must only contain letters, numbers, dashes, and underscores.',
      'ascii': 'The :attribute field must only contain single-byte alphanumeric characters and symbols.',
      'lowercase': 'The :attribute field must be lowercase.',
      'uppercase': 'The :attribute field must be uppercase.',
      'regex': 'The :attribute field format is invalid.',
      'not_regex': 'The :attribute field format is invalid.',
      'min.numeric': 'The :attribute field must be at least :min.',
      'min.string': 'The :attribute field must be at least :min characters.',
      'min.array': 'The :attribute field must have at least :min items.',
      'max.numeric': 'The :attribute field must not be greater than :max.',
      'max.string':
          'The :attribute field must not be greater than :max characters.',
      'max.array': 'The :attribute field must not have more than :max items.',
      'between.numeric': 'The :attribute field must be between :min and :max.',
      'between.string':
          'The :attribute field must be between :min and :max characters.',
      'between.array':
          'The :attribute field must have between :min and :max items.',
      'size.numeric': 'The :attribute field must be :size.',
      'size.string': 'The :attribute field must be :size characters.',
      'size.array': 'The :attribute field must contain :size items.',
      'min.file': 'The :attribute field must be at least :min kilobytes.',
      'max.file':
          'The :attribute field must not be greater than :max kilobytes.',
      'between.file':
          'The :attribute field must be between :min and :max kilobytes.',
      'size.file': 'The :attribute field must be :size kilobytes.',
      'file': 'The :attribute field must be a file.',
      'image': 'The :attribute field must be an image.',
      'mimes': 'The :attribute field must be a file of type: :values.',
      'mimetypes': 'The :attribute field must be a file of type: :values.',
      'extensions': 'The :attribute field must have one of the following extensions: :values.',
      'uploaded': 'The :attribute failed to upload.',
      'digits': 'The :attribute field must be :digits digits.',
      'digits_between':
          'The :attribute field must be between :min and :max digits.',
      'in': 'The selected :attribute is invalid.',
      'not_in': 'The selected :attribute is invalid.',
      'distinct': 'The :attribute field has a duplicate value.',
      'confirmed': 'The :attribute field confirmation does not match.',
      'same': 'The :attribute field must match :other.',
      'different': 'The :attribute field and :other must be different.',
      'starts_with':
          'The :attribute field must start with one of the following: :values.',
      'ends_with':
          'The :attribute field must end with one of the following: :values.',
      'date': 'The :attribute field must be a valid date.',
      'date_format': 'The :attribute field must match the format :format.',
      'after': 'The :attribute field must be a date after :date.',
      'after_or_equal':
          'The :attribute field must be a date after or equal to :date.',
      'before': 'The :attribute field must be a date before :date.',
      'before_or_equal':
          'The :attribute field must be a date before or equal to :date.',
      'unique': 'The :attribute has already been taken.',
      'exists': 'The selected :attribute is invalid.',
      'password.letters':
          'The :attribute field must contain at least one letter.',
      'password.mixed': 'The :attribute field must contain at least one uppercase and one lowercase letter.',
      'password.numbers':
          'The :attribute field must contain at least one number.',
      'password.symbols':
          'The :attribute field must contain at least one symbol.',
      'custom': 'The :attribute field is invalid.',
    },
    'id': {
      'required': 'Kolom :attribute wajib diisi.',
      'present': 'Kolom :attribute harus ada.',
      'filled': 'Kolom :attribute harus memiliki nilai.',
      'prohibited': 'Kolom :attribute tidak diperbolehkan.',
      'required_if':
          'Kolom :attribute wajib diisi bila :other bernilai :value.',
      'required_unless':
          'Kolom :attribute wajib diisi kecuali :other bernilai :values.',
      'required_with': 'Kolom :attribute wajib diisi bila :values ada.',
      'required_without':
          'Kolom :attribute wajib diisi bila :values tidak ada.',
      'string': 'Kolom :attribute harus berupa teks.',
      'integer': 'Kolom :attribute harus berupa bilangan bulat.',
      'numeric': 'Kolom :attribute harus berupa angka.',
      'boolean': 'Kolom :attribute harus bernilai true atau false.',
      'array': 'Kolom :attribute harus berupa array.',
      'map': 'Kolom :attribute harus berupa objek.',
      'email': 'Kolom :attribute harus berupa alamat email yang valid.',
      'url': 'Kolom :attribute harus berupa URL yang valid.',
      'uuid': 'Kolom :attribute harus berupa UUID yang valid.',
      'ulid': 'Kolom :attribute harus berupa ULID yang valid.',
      'ip': 'Kolom :attribute harus berupa alamat IP yang valid.',
      'ipv4': 'Kolom :attribute harus berupa alamat IPv4 yang valid.',
      'ipv6': 'Kolom :attribute harus berupa alamat IPv6 yang valid.',
      'json': 'Kolom :attribute harus berupa string JSON yang valid.',
      'alpha': 'Kolom :attribute hanya boleh berisi huruf.',
      'alpha_num': 'Kolom :attribute hanya boleh berisi huruf dan angka.',
      'alpha_dash': 'Kolom :attribute hanya boleh berisi huruf, angka, tanda hubung, dan garis bawah.',
      'ascii': 'Kolom :attribute hanya boleh berisi karakter alfanumerik dan simbol single-byte.',
      'lowercase': 'Kolom :attribute harus huruf kecil.',
      'uppercase': 'Kolom :attribute harus huruf besar.',
      'regex': 'Format kolom :attribute tidak valid.',
      'not_regex': 'Format kolom :attribute tidak valid.',
      'min.numeric': 'Kolom :attribute minimal :min.',
      'min.string': 'Kolom :attribute minimal :min karakter.',
      'min.array': 'Kolom :attribute minimal :min item.',
      'max.numeric': 'Kolom :attribute maksimal :max.',
      'max.string': 'Kolom :attribute maksimal :max karakter.',
      'max.array': 'Kolom :attribute maksimal :max item.',
      'between.numeric': 'Kolom :attribute harus antara :min dan :max.',
      'between.string': 'Kolom :attribute harus antara :min dan :max karakter.',
      'between.array': 'Kolom :attribute harus antara :min dan :max item.',
      'size.numeric': 'Kolom :attribute harus bernilai :size.',
      'size.string': 'Kolom :attribute harus :size karakter.',
      'size.array': 'Kolom :attribute harus berisi :size item.',
      'min.file': 'Kolom :attribute minimal :min kilobyte.',
      'max.file': 'Kolom :attribute maksimal :max kilobyte.',
      'between.file': 'Kolom :attribute harus antara :min dan :max kilobyte.',
      'size.file': 'Kolom :attribute harus :size kilobyte.',
      'file': 'Kolom :attribute harus berupa file.',
      'image': 'Kolom :attribute harus berupa gambar.',
      'mimes': 'Kolom :attribute harus berupa file bertipe: :values.',
      'mimetypes': 'Kolom :attribute harus berupa file bertipe: :values.',
      'extensions':
          'Kolom :attribute harus berekstensi salah satu dari: :values.',
      'uploaded': 'Kolom :attribute gagal diunggah.',
      'digits': 'Kolom :attribute harus :digits digit.',
      'digits_between': 'Kolom :attribute harus antara :min dan :max digit.',
      'in': 'Kolom :attribute yang dipilih tidak valid.',
      'not_in': 'Kolom :attribute yang dipilih tidak valid.',
      'distinct': 'Kolom :attribute memiliki nilai duplikat.',
      'confirmed': 'Konfirmasi kolom :attribute tidak cocok.',
      'same': 'Kolom :attribute harus sama dengan :other.',
      'different': 'Kolom :attribute dan :other harus berbeda.',
      'starts_with': 'Kolom :attribute harus diawali salah satu dari: :values.',
      'ends_with': 'Kolom :attribute harus diakhiri salah satu dari: :values.',
      'date': 'Kolom :attribute harus berupa tanggal yang valid.',
      'date_format': 'Kolom :attribute harus sesuai dengan format :format.',
      'after': 'Kolom :attribute harus tanggal setelah :date.',
      'after_or_equal':
          'Kolom :attribute harus tanggal setelah atau sama dengan :date.',
      'before': 'Kolom :attribute harus tanggal sebelum :date.',
      'before_or_equal':
          'Kolom :attribute harus tanggal sebelum atau sama dengan :date.',
      'unique': ':attribute sudah digunakan.',
      'exists': 'Kolom :attribute yang dipilih tidak valid.',
      'password.letters':
          'Kolom :attribute harus mengandung minimal satu huruf.',
      'password.mixed': 'Kolom :attribute harus mengandung minimal satu huruf besar dan satu huruf kecil.',
      'password.numbers':
          'Kolom :attribute harus mengandung minimal satu angka.',
      'password.symbols':
          'Kolom :attribute harus mengandung minimal satu simbol.',
      'custom': 'Kolom :attribute tidak valid.',
    },
  };

  /// The English messages of Laravel 8 and 9 (`The :attribute must be a
  /// string.`) where they differ from 10 to 13, used under
  /// `COMPAT_LARAVEL_VERSION` 8 or 9. Source: laravel/laravel 9.x
  /// `lang/en/validation.php` (8.x `resources/lang/en/validation.php`
  /// has the same text for every rule it knows).
  static const Map<String, String> legacyEnglish = {
    'string': 'The :attribute must be a string.',
    'integer': 'The :attribute must be an integer.',
    'numeric': 'The :attribute must be a number.',
    'array': 'The :attribute must be an array.',
    'email': 'The :attribute must be a valid email address.',
    'url': 'The :attribute must be a valid URL.',
    'uuid': 'The :attribute must be a valid UUID.',
    'ulid': 'The :attribute must be a valid ULID.',
    'ip': 'The :attribute must be a valid IP address.',
    'ipv4': 'The :attribute must be a valid IPv4 address.',
    'ipv6': 'The :attribute must be a valid IPv6 address.',
    'json': 'The :attribute must be a valid JSON string.',
    'alpha': 'The :attribute must only contain letters.',
    'alpha_num': 'The :attribute must only contain letters and numbers.',
    'alpha_dash': 'The :attribute must only contain letters, numbers, dashes and underscores.',
    'ascii': 'The :attribute must only contain single-byte alphanumeric characters and symbols.',
    'lowercase': 'The :attribute must be lowercase.',
    'uppercase': 'The :attribute must be uppercase.',
    'regex': 'The :attribute format is invalid.',
    'not_regex': 'The :attribute format is invalid.',
    'min.numeric': 'The :attribute must be at least :min.',
    'min.string': 'The :attribute must be at least :min characters.',
    'min.array': 'The :attribute must have at least :min items.',
    'max.numeric': 'The :attribute must not be greater than :max.',
    'max.string': 'The :attribute must not be greater than :max characters.',
    'max.array': 'The :attribute must not have more than :max items.',
    'between.numeric': 'The :attribute must be between :min and :max.',
    'between.string':
        'The :attribute must be between :min and :max characters.',
    'between.array': 'The :attribute must have between :min and :max items.',
    'size.numeric': 'The :attribute must be :size.',
    'size.string': 'The :attribute must be :size characters.',
    'size.array': 'The :attribute must contain :size items.',
    'min.file': 'The :attribute must be at least :min kilobytes.',
    'max.file': 'The :attribute must not be greater than :max kilobytes.',
    'between.file': 'The :attribute must be between :min and :max kilobytes.',
    'size.file': 'The :attribute must be :size kilobytes.',
    'file': 'The :attribute must be a file.',
    'image': 'The :attribute must be an image.',
    'mimes': 'The :attribute must be a file of type: :values.',
    'mimetypes': 'The :attribute must be a file of type: :values.',
    'digits': 'The :attribute must be :digits digits.',
    'digits_between': 'The :attribute must be between :min and :max digits.',
    'confirmed': 'The :attribute confirmation does not match.',
    'same': 'The :attribute and :other must match.',
    'different': 'The :attribute and :other must be different.',
    'starts_with':
        'The :attribute must start with one of the following: :values.',
    'ends_with': 'The :attribute must end with one of the following: :values.',
    'date': 'The :attribute is not a valid date.',
    'date_format': 'The :attribute does not match the format :format.',
    'after': 'The :attribute must be a date after :date.',
    'after_or_equal': 'The :attribute must be a date after or equal to :date.',
    'before': 'The :attribute must be a date before :date.',
    'before_or_equal':
        'The :attribute must be a date before or equal to :date.',
    'password.letters': 'The :attribute must contain at least one letter.',
    'password.mixed': 'The :attribute must contain at least one uppercase and one lowercase letter.',
    'password.numbers': 'The :attribute must contain at least one number.',
    'password.symbols': 'The :attribute must contain at least one symbol.',
  };

  /// Resolves [key] for [locale] (falling back to `en`, then the key itself)
  /// and substitutes `:attribute` plus every entry of [parameters].
  static String resolve(
    String key, {
    required String locale,
    required String attribute,
    Map<String, Object?> parameters = const {},
    Map<String, String> overrides = const {},
    int? laravelCompat,
  }) {
    final legacy = (laravelCompat ?? currentLaravelCompat()) <= 9;
    final template =
        overrides[key] ??
        (locale == 'en' ? null : translations[locale]?[key]) ??
        (legacy ? legacyEnglish[key] : null) ??
        translations['en']![key] ??
        (key.contains(' ') ? key : translations['en']!['custom']!);
    var message = template.replaceAll(':attribute', attribute);
    for (final entry in parameters.entries) {
      message = message.replaceAll(':${entry.key}', '${entry.value}');
    }
    return message;
  }
}
