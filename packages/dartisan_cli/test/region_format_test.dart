import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dart_style/dart_style.dart';
import 'package:dartisan_cli/src/model_sync.dart';
import 'package:dartisan_cli/src/region_format.dart';
import 'package:dartisan_cli/src/stubs.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

/// Generated regions are laid out as `dart format` would for the project,
/// whatever the length of the model and column names; code outside the
/// regions is never touched.
void main() {
  const name = 'SubscriptionBillingAddressHistoryEntry';
  const columns = [
    ColumnInfo(
      name: 'id',
      type: 'INTEGER',
      nullable: false,
      primary: true,
      autoIncrement: true,
    ),
    ColumnInfo(name: 'name', type: 'VARCHAR', nullable: false),
    ColumnInfo(
      name: 'previous_billing_address_line_one',
      type: 'VARCHAR',
      nullable: false,
    ),
    ColumnInfo(
      name: 'previous_postal_code_value',
      type: 'VARCHAR',
      nullable: true,
    ),
    ColumnInfo(name: 'created_at', type: 'TEXT', nullable: true),
  ];

  /// A model as `make:model` writes it, with fillable columns and a
  /// hand-written method outside the regions laid out badly on purpose.
  String model() {
    final made = renderStub(builtInStubs['model']!, {
      'class': name,
      'table': 'subscription_billing_address_history_entries',
      'softDeletes': '',
    });
    final withFillable = made.replaceFirst(
      '    factory: $name.new,',
      "    factory: $name.new,\n    fillable: ['name', "
          "'previous_billing_address_line_one', 'previous_postal_code_value'],",
    );
    return '$withFillable\nint   handWritten( int a ,int b ){return a+b;}\n';
  }

  String outside(String source) {
    final buffer = StringBuffer();
    var rest = source;
    for (final region in ['statics', 'accessors', 'ids']) {
      final start = rest.indexOf('// <dartisan:$region>');
      final end = rest.indexOf('// </dartisan:$region>');
      if (start == -1 || end < start) {
        continue;
      }
      buffer.write(rest.substring(0, start));
      rest = rest.substring(end);
    }
    return '$buffer$rest';
  }

  ModelSync sync(
    String source,
    RegionFormatter formatter, {
    bool ids = false,
  }) => syncModelSource(
    source,
    ModelSource.parse(source)!,
    columns,
    formatter: formatter,
    idStub: ids ? builtInStubs['model.id'] : null,
  );

  for (final width in [80, 100]) {
    test('regions are format-clean at page width $width', () {
      final formatter = RegionFormatter(pageWidth: width);
      final dart = DartFormatter(
        languageVersion: DartFormatter.latestLanguageVersion,
        pageWidth: width,
      );
      // The file around the regions is format-clean except handWritten.
      final source = model();
      for (final ids in [false, true]) {
        final synced = sync(source, formatter, ids: ids);
        expect(synced.warnings, isNot(contains(contains('formatted'))));
        final once = synced.source!;
        // Formatting the whole file changes nothing inside the regions
        // model:sync writes. (The statics region holds what make:model
        // wrote: it belongs to the application once written.)
        String region(String s, String name) {
          final start = s.indexOf('// <dartisan:$name>');
          return start == -1
              ? ''
              : s.substring(start, s.indexOf('// </dartisan:$name>'));
        }

        final formatted = dart.format(once);
        for (final name in ['accessors', 'ids']) {
          expect(
            region(formatted, name),
            region(once, name),
            reason: '$name, ids: $ids',
          );
        }
        expect(region(once, 'ids').isEmpty, !ids);
        // Outside the regions, byte-identical to the input.
        // (--typed-ids appends the ids region at the end of the file.)
        expect(
          outside(once),
          ids ? '${outside(source)}\n// </dartisan:ids>\n' : outside(source),
        );
        expect(once, contains('int   handWritten( int a ,int b )'));
        // A second sync changes nothing.
        expect(sync(once, formatter, ids: ids).source, once);
      }
    });
  }

  test('page width 100 lays out differently from 80', () {
    final at80 = sync(model(), RegionFormatter()).source!;
    final at100 = sync(model(), RegionFormatter(pageWidth: 100)).source!;
    expect(at80, isNot(at100));
    expect(
      at80,
      contains(
        '  String get previousBillingAddressLineOne =>\n'
        "      getAttr('previous_billing_address_line_one');",
      ),
    );
    expect(
      at100,
      contains(
        '  String get previousBillingAddressLineOne => '
        "getAttr('previous_billing_address_line_one');",
      ),
    );
  });

  test('without a formatter, the regions are written as generated', () {
    final raw = syncModelSource(
      model(),
      ModelSource.parse(model())!,
      columns,
    ).source!;
    expect(
      raw,
      contains(
        '  String get previousBillingAddressLineOne => '
        "getAttr('previous_billing_address_line_one');",
      ),
    );
  });

  test('code it cannot parse is returned as given, with the reason', () {
    final formatter = RegionFormatter();
    const broken = '  int get x => ;';
    expect(formatter.members(broken), broken);
    expect(formatter.lastFailure, isNotNull);
    expect(formatter.members('  int get x => 1;'), '  int get x => 1;');
    expect(formatter.lastFailure, isNull);
    expect(formatter.topLevel('extension type X('), 'extension type X(');
    expect(formatter.lastFailure, isNotNull);
  });

  test('forProject reads the SDK lower bound and the page width', () {
    final root = Directory.systemTemp.createTempSync('region_format_');
    addTearDown(() => root.deleteSync(recursive: true));
    final defaults = RegionFormatter.forProject(root.path);
    expect(defaults.pageWidth, 80);
    expect(defaults.languageVersion, DartFormatter.latestLanguageVersion);
    File(p.join(root.path, 'pubspec.yaml'))
        .writeAsStringSync('name: x\nenvironment:\n  sdk: ^3.6.0\n');
    File(p.join(root.path, 'analysis_options.yaml')).writeAsStringSync(
      'include: package:lints/recommended.yaml\n\n'
      'formatter:\n  trailing_commas: preserve\n  page_width: 120\n',
    );
    final project = RegionFormatter.forProject(root.path);
    expect(project.pageWidth, 120);
    expect(project.languageVersion, Version(3, 6, 0));
  });

  group('the SDK lower bound of unusual pubspecs', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('region_sdk_'));
    tearDown(() => root.deleteSync(recursive: true));

    RegionFormatter withPubspec(String pubspec) {
      File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync(pubspec);
      return RegionFormatter.forProject(root.path);
    }

    const member = '  int get value => 1;';

    test('newer than this dart_style knows: the latest it knows', () {
      final formatter = withPubspec('name: x\nenvironment:\n  sdk: ^9.0.0\n');
      expect(formatter.languageVersion, DartFormatter.latestLanguageVersion);
      expect(formatter.members(member), member);
      expect(formatter.lastFailure, isNull);
    });

    test('very old: kept, and still formats', () {
      final formatter = withPubspec(
        "name: x\nenvironment:\n  sdk: '>=2.19.0 <4.0.0'\n",
      );
      expect(formatter.languageVersion, Version(2, 19, 0));
      expect(formatter.members(member), member);
      expect(formatter.lastFailure, isNull);
    });

    test('a dependency on an SDK above environment is not read', () {
      final formatter = withPubspec(
        'name: x\n'
        'dependencies:\n'
        '  flutter:\n'
        '    sdk: flutter\n'
        '# a comment at column 0\n'
        'environment:\n'
        '  # the Dart SDK\n'
        '  sdk: ^3.8.0\n',
      );
      expect(formatter.languageVersion, Version(3, 8, 0));
    });

    test('no environment: the latest', () {
      final formatter = withPubspec(
        'name: x\ndependencies:\n  flutter:\n    sdk: flutter\n',
      );
      expect(formatter.languageVersion, DartFormatter.latestLanguageVersion);
    });
  });
}
