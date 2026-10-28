import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:daravel_excel/daravel_excel.dart';
import 'package:daravel_excel/src/csv.dart';
import 'package:daravel_excel/src/zip.dart';
import 'package:test/test.dart';

final class Student extends Model {
  static final ModelDefinition<Student> definition = ModelDefinition<Student>(
    table: 'students',
    factory: Student.new,
    fillable: ['nisn', 'name', 'email', 'score'],
  );

  @override
  ModelDefinition<Student> get modelDefinition => Student.definition;

  String get name => getAttr('name');
}

final class CreateStudents extends Migration {
  const CreateStudents();

  @override
  String get name => '2026_01_01_000000_create_students';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('students', (table) {
    table.id();
    table.string('nisn').unique();
    table.string('name');
    table.string('email').nullable();
    table.float('score').nullable();
    table.timestamps();
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('students');
}

final class StudentsExport
    implements
        FromQuery,
        WithHeadings,
        WithMapping,
        WithTitle,
        WithColumnFormatting,
        WithCustomChunkSize {
  @override
  int get chunkSize => 3;

  @override
  Object query() => Student.definition.query().orderBy('nisn');

  @override
  List<Object?> headings() => ['NISN', 'Nama Lengkap', 'Nilai'];

  @override
  List<Object?> map(Object? row) {
    final student = row! as Student;
    return [
      student.getAttr<Object?>('nisn'),
      student.name.toUpperCase(),
      student.getAttr<Object?>('score'),
    ];
  }

  @override
  String title() => 'Siswa: 2026/27';

  @override
  Map<String, String> columnFormats() => {'C': NumberFormat.number00};
}

final class ListExport implements FromCollection, WithHeadings {
  ListExport(this.rows, [this.heads = const []]);
  final List<Object?> rows;
  final List<Object?> heads;

  @override
  List<Object?> collection() => rows;

  @override
  List<Object?> headings() => heads;
}

final class TwoSheets implements WithMultipleSheets {
  @override
  List<Object> sheets() => [
    _Titled(
      'Satu',
      ListExport([
        [1],
      ]),
    ),
    _Titled(
      'Dua',
      ListExport([
        ['a', 'b'],
      ]),
    ),
  ];
}

final class _Titled implements FromCollection, WithTitle {
  _Titled(this.name, this.inner);
  final String name;
  final ListExport inner;
  @override
  List<Object?> collection() => inner.rows;
  @override
  String title() => name;
}

final class StudentsImport
    with WithHeadingRow, SkipsEmptyRows
    implements ToModel, WithValidation, WithCustomValidationAttributes {
  @override
  Model? model(Map<String, Object?> row) => Student.definition.newInstance({
    'nisn': '${row['nisn']}',
    'name': row['nama_lengkap'],
    'email': row['email'],
    'score': row['nilai'],
  });

  @override
  Map<String, Object> rules() => {
    'nisn': 'required|unique:students,nisn',
    'nama_lengkap': 'required|string|max:20',
    'email': 'nullable|email',
    '*.nilai': 'nullable|numeric|between:0,100',
  };

  @override
  Map<String, String> customValidationAttributes() => {'nilai': 'score'};
}

final class LenientImport extends StudentsImport with SkipsFailures {}

final class BatchImport extends StudentsImport implements WithBatchInserts {
  @override
  int get batchSize => 2;
}

final class RowsImport implements OnEachRow, WithStartRow, WithLimit {
  final List<ExcelRow> rows = [];
  @override
  void onRow(ExcelRow row) => rows.add(row);
  @override
  int startRow() => 2;
  @override
  int limit() => 2;
}

final class ChunkedCollection
    with WithHeadingRow
    implements ToCollection, WithChunkReading {
  final List<int> sizes = [];
  @override
  int get chunkSize => 2;
  @override
  void collection(List<Map<String, Object?>> rows) => sizes.add(rows.length);
}

final class SecondSheet implements WithMultipleSheetImports {
  final RowsImport rows = RowsImport();
  @override
  Map<Object, Object> sheets() => {'Dua': rows};
}

void main() {
  late Directory dir;
  late Application app;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('daravel_excel_');
    app = Application.configure(basePath: dir.path)
        .withEnv({
          'APP_ENV': 'testing',
          'LOG_LEVEL': 'error',
          'DB_DATABASE': '${dir.path}/app.sqlite',
        })
        .withMigrations(const [CreateStudents()])
        .withRouting(
          apiPrefix: '',
          api: (router) {
            router.get(
              '/students.xlsx',
              (_) => Excel.download(StudentsExport(), 'students.xlsx'),
            );
            router.post('/import', (Request request) async {
              await Excel.import(
                StudentsImport(),
                (await request.file('file'))!,
              );
              return {'ok': true};
            });
          },
        )
        .create();
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
  });

  tearDown(() async {
    await app.shutdown();
    dir.deleteSync(recursive: true);
  });

  Future<void> seed(int n) => app.run(() async {
    for (var i = 1; i <= n; i++) {
      await Student.definition.query().create({
        'nisn': '00${100 + i}',
        'name': 'Siswa $i',
        'score': 70 + i + 0.5,
      });
    }
  });

  Future<List<List<Map<String, Object?>>>> read(
    List<int> bytes, {
    bool heading = false,
  }) => Excel.toArray(bytes, type: ExcelType.xlsx, headingRow: heading);

  group('XLSX writing and reading', () {
    test('every cell type round-trips', () async {
      final bytes = await Excel.raw(
        ListExport(
          [
            ['plain', 42, 3.25, true, false, null, DateTime.utc(2026, 10, 28)],
            [
              '  spaced  ',
              -7,
              1e-3,
              'a & b < c > "d"',
              'ünïcødé 🌴',
              '',
              DateTime.utc(2026, 10, 28, 7, 30),
            ],
            ['bad \u0000\u0001 chars', 9007199254740991],
          ],
          ['A', 'B'],
        ),
        ExcelType.xlsx,
      );
      final [rows] = await read(bytes);
      expect(rows[0], {'0': 'A', '1': 'B'});
      expect(rows[1].values.toList(), [
        'plain',
        42,
        3.25,
        true,
        false,
        null,
        46323,
      ]);
      expect(rows[2]['0'], '  spaced  ');
      expect(rows[2]['3'], 'a & b < c > "d"');
      expect(rows[2]['4'], 'ünïcødé 🌴');
      expect(
        ExcelDate.toDateTime(rows[2]['6']! as num),
        DateTime.utc(2026, 10, 28, 7, 30),
      );
      expect(rows[3]['0'], 'bad  chars');
      expect(rows[3]['1'], 9007199254740991);
    });

    test('sheets, titles and formats in the package parts', () async {
      final bytes = await Excel.raw(TwoSheets(), ExcelType.xlsx);
      final reader = await XlsxReader.open(RandomAccessSource.bytes(bytes));
      expect([for (final s in reader.sheets) s.name], ['Satu', 'Dua']);
      await reader.close();
      final dates = await Excel.raw(
        ListExport([
          [DateTime.utc(2026)],
        ]),
        ExcelType.xlsx,
      );
      final zip = await ZipReader.open(RandomAccessSource.bytes(dates));
      final styles = await utf8.decodeStream(zip.read('xl/styles.xml'));
      expect(styles, contains('formatCode="yyyy-mm-dd"'));
      final sheet = await utf8.decodeStream(
        zip.read('xl/worksheets/sheet1.xml'),
      );
      expect(sheet, contains('<c r="A1" s="1"><v>46023</v></c>'));
    });

    test('a ZIP bomb is refused, a non-ZIP is refused', () async {
      final big = await Excel.raw(
        ListExport([
          for (var i = 0; i < 2000; i++) ['x' * 100],
        ]),
        ExcelType.xlsx,
      );
      final zip = await ZipReader.open(RandomAccessSource.bytes(big));
      await expectLater(
        zip.read('xl/worksheets/sheet1.xml', maxBytes: 1000).drain<void>(),
        throwsA(isA<ZipFormatException>()),
      );
      await expectLater(
        Excel.toArray(
          utf8.encode('not a zip at all, sorry'),
          type: ExcelType.xlsx,
        ),
        throwsA(isA<ZipFormatException>()),
      );
    });
  });

  group('CSV', () {
    test('every field enclosed, as PhpSpreadsheet writes', () async {
      final bytes = await Excel.raw(
        ListExport(
          [
            ['a "q"', 'line\nbreak', 2.0, true, null, DateTime.utc(2026, 1, 2)],
          ],
          ['x', 'y'],
        ),
        ExcelType.csv,
      );
      expect(
        utf8.decode(bytes),
        '"x","y"\n"a ""q""","line\nbreak","2","TRUE","","2026-01-02"\n',
      );
    });

    test('reading: quotes, CRLF, BOM, detected delimiters, numbers', () async {
      Future<List<List<String>>> parse(
        String text, [
        CsvSettings settings = const CsvSettings(),
      ]) => parseCsv(Stream.value(utf8.encode(text)), settings).toList();
      expect(await parse('﻿a,"b ""c""",\r\n"d\ne",f'), [
        ['a', 'b "c"', ''],
        ['d\ne', 'f'],
      ]);
      expect(await parse('a;b;c\n1;2;3'), [
        ['a', 'b', 'c'],
        ['1', '2', '3'],
      ]);
      final [rows] = await Excel.toArray(
        utf8.encode('nisn,nilai,aktif\n0123,42,TRUE\n9,4.5,false\n+7,5.,yes\n'),
        type: ExcelType.csv,
        headingRow: true,
      );
      expect(rows, [
        {'nisn': '0123', 'nilai': 42, 'aktif': true},
        {'nisn': 9, 'nilai': 4.5, 'aktif': false},
        {'nisn': 7, 'nilai': 5.0, 'aktif': 'yes'},
      ]);
    });
  });

  group('exports', () {
    test('a query read in chunks, mapped, formatted', () async {
      await seed(7);
      final bytes = await app.run(
        () => Excel.raw(StudentsExport(), ExcelType.xlsx),
      );
      final reader = await XlsxReader.open(RandomAccessSource.bytes(bytes));
      expect(reader.sheets.single.name, 'Siswa 202627');
      final rows = await reader.rows(reader.sheets.single).toList();
      await reader.close();
      expect(rows.first.cells, ['NISN', 'Nama Lengkap', 'Nilai']);
      expect(rows, hasLength(8));
      expect(rows[1].cells, ['00101', 'SISWA 1', 71.5]);
      expect(rows.last.number, 8);
    });

    test(
      'download streams with the right headers; store writes a disk',
      () async {
        await seed(3);
        final response = await app.handle(Request.fake(path: '/students.xlsx'));
        expect(response.status, 200);
        expect(
          response.headers.first('content-type'),
          startsWith(
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          ),
        );
        expect(
          response.headers.first('content-disposition'),
          contains('filename="students.xlsx"'),
        );
        final body = await response.bodyBytes();
        expect(body.sublist(0, 2), [0x50, 0x4b]);
        expect((await read(body)).single, hasLength(4));

        await app.run(() async {
          final disk = Storage.fake('reports');
          await Excel.store(
            StudentsExport(),
            'out/students.csv',
            disk: 'reports',
          );
          final csv = await disk.get('out/students.csv');
          expect(csv.split('\n').first, '"NISN","Nama Lengkap","Nilai"');
        });
      },
    );
  });

  group('imports', () {
    List<int> sheet(List<List<Object?>> rows) => _xlsx(rows);

    test('rows become models, keyed by slugged headings', () async {
      await app.run(() async {
        await Excel.import(
          StudentsImport(),
          sheet([
            ['NISN', 'Nama Lengkap', 'Email', 'Nilai'],
            ['111', 'Ana', 'ana@x.test', 90],
            [null, null, null, null],
            ['222', 'Bo', null, 75.5],
          ]),
          type: ExcelType.xlsx,
        );
        final all = await Student.definition.query().orderBy('nisn').get();
        expect([for (final s in all) s.name], ['Ana', 'Bo']);
        expect(all.last.getAttr<Object?>('score'), 75.5);
      });
    });

    test('failures name the sheet row; nothing is saved', () async {
      final file = sheet([
        ['NISN', 'Nama Lengkap', 'Email', 'Nilai'],
        ['111', 'Ana', 'ana@x.test', 90],
        ['222', 'B' * 30, 'not-an-email', 101],
        [null, 'Cy', null, null],
      ]);
      await app.run(() async {
        try {
          await Excel.import(StudentsImport(), file, type: ExcelType.xlsx);
          fail('expected a validation exception');
        } on ExcelValidationException catch (e) {
          expect(
            {for (final f in e.failures) '${f.row}.${f.attribute}'},
            {'3.nama_lengkap', '3.email', '3.nilai', '4.nisn'},
          );
          final score = e.failures.firstWhere((f) => f.attribute == 'nilai');
          expect(
            score.errors.single,
            'The score field must be between 0 and 100.',
          );
          expect(score.values['nisn'], '222');
          expect(
            score.toList().single,
            startsWith('There was an error on row 3. '),
          );
          expect(e.status, 422);
        }
        expect(
          await Student.definition.query().count(),
          0,
          reason: 'rolled back',
        );
      });

      final response = await app.handle(
        Request.fake(
          method: 'POST',
          path: '/import',
          files: {'file': UploadedFile.fromBytes(file, name: 'students.xlsx')},
        ),
      );
      expect(response.status, 422);
      final body =
          jsonDecode(await response.bodyText()) as Map<String, Object?>;
      expect((body['errors']! as Map).keys, contains('3.email'));
    });

    test('SkipsFailures keeps the valid rows and the failures', () async {
      await app.run(() async {
        final import = LenientImport();
        await Excel.import(
          import,
          sheet([
            ['NISN', 'Nama Lengkap'],
            ['111', 'Ana'],
            ['222', null],
            ['333', 'Cy'],
          ]),
          type: ExcelType.xlsx,
        );
        expect([for (final f in import.failures()) f.row], [3]);
        expect(await Student.definition.query().count(), 2);
      });
    });

    test('batch inserts, chunks, start rows, limits, sheets by name', () async {
      await app.run(() async {
        await Excel.import(
          BatchImport(),
          sheet([
            ['NISN', 'Nama Lengkap'],
            for (var i = 1; i <= 5; i++) ['$i', 'S$i'],
          ]),
          type: ExcelType.xlsx,
        );
        expect(await Student.definition.query().count(), 5);

        final chunked = ChunkedCollection();
        await Excel.import(
          chunked,
          utf8.encode('a,b\n1,2\n3,4\n5,6\n'),
          type: ExcelType.csv,
        );
        expect(chunked.sizes, [2, 1]);

        final two = await Excel.raw(TwoSheets(), ExcelType.xlsx);
        final rows = RowsImport();
        await Excel.import(
          rows,
          sheet([
            ['h'],
            ['r2'],
            ['r3'],
            ['r4'],
          ]),
          type: ExcelType.xlsx,
        );
        expect([for (final r in rows.rows) r.index], [2, 3]);
        expect(rows.rows.first['0'], 'r2');

        final second = SecondSheet();
        await Excel.import(second, two, type: ExcelType.xlsx);
        expect(
          second.rows.rows,
          isEmpty,
          reason: 'Dua has one row, before startRow 2',
        );
      });
    });

    test('a file on a disk, an upload kept on disk', () async {
      await app.run(() async {
        final disk = Storage.fake('uploads');
        await disk.put('in/students.csv', 'NISN,Nama Lengkap\n555,Eko\n');
        await Excel.import(
          StudentsImport(),
          'in/students.csv',
          disk: 'uploads',
        );
        final path = '${dir.path}/upload.xlsx';
        File(path).writeAsBytesSync(
          sheet([
            ['NISN', 'Nama Lengkap'],
            ['666', 'Fa'],
          ]),
        );
        await Excel.import(
          StudentsImport(),
          UploadedFile.temporary(
            path: path,
            clientName: 'upload.xlsx',
            clientMimeType: 'application/octet-stream',
            size: File(path).lengthSync(),
            header: const [],
          ),
        );
        expect(await Student.definition.query().count(), 2);
      });
    });
  });

  test('Excel dates and column letters', () {
    expect(ExcelDate.fromDateTime(DateTime.utc(1900, 1, 1)), 1);
    expect(ExcelDate.fromDateTime(DateTime.utc(1900, 3, 1)), 61);
    expect(ExcelDate.toDateTime(45658.5), DateTime.utc(2025, 1, 1, 12));
    expect(
      [
        for (final i in [0, 25, 26, 701, 702]) columnLetter(i),
      ],
      ['A', 'Z', 'AA', 'ZZ', 'AAA'],
    );
    expect(columnIndex('aaa'), 702);
  });
}

/// An XLSX of [rows] written by the package (the interop script checks
/// files from Laravel Excel).
List<int> _xlsx(List<List<Object?>> rows) {
  final writer = XlsxWriter()..startSheet('Sheet1');
  for (final row in rows) {
    writer.addRow(row);
  }
  writer.finish();
  final builder = BytesBuilder();
  for (final chunk in writer.take()) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}
