import 'package:daravel/daravel.dart';
import 'package:daravel_excel/daravel_excel.dart';

/// A report of the numbers 1 to 1 000 with their squares.
final class SquaresExport
    implements FromGenerator, WithHeadings, WithColumnFormatting {
  @override
  List<Object?> headings() => ['n', 'n²', 'Checked at'];

  @override
  Stream<Object?> generator() async* {
    for (var n = 1; n <= 1000; n++) {
      yield [n, n * n, DateTime.now()];
    }
  }

  @override
  Map<String, String> columnFormats() => {
    'B': NumberFormat.numberCommaSeparated1,
  };
}

/// Imports rows keyed by their headings and answers how many came.
final class CountImport with WithHeadingRow implements ToCollection {
  int count = 0;

  @override
  void collection(List<Map<String, Object?>> rows) => count = rows.length;
}

/// `GET /squares.xlsx` downloads the report; `POST /count` with a
/// `file` upload counts its rows.
Application createApp() => Application.configure(basePath: '.')
    .withRouting(
      api: (router) {
        router.get(
          '/squares.xlsx',
          (_) => Excel.download(SquaresExport(), 'squares.xlsx'),
        );
        router.post('/count', (Request request) async {
          final import = CountImport();
          await Excel.import(import, (await request.file('file'))!);
          return {'rows': import.count};
        });
      },
    )
    .create();

Future<void> main() async => Application.serveWith(createApp);
