import 'package:daravel_lints/daravel_lints.dart';

/// Lints a source string the way `dartisan lint` lints `lib/app`.
void main() {
  const source = r'''
import 'package:daravel/daravel.dart';

Future<Object?> search(String term) =>
    DB.select("SELECT * FROM posts WHERE title = '$term'");

void debug() => print('hi');
''';
  final issues = lintSource(source, 'lib/app/http/controllers/search.dart');
  for (final issue in issues) {
    print(issue); // path:line:column  rule  message
  }
}
