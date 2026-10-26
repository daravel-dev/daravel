import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Translations of the guide (`docs/guide/id/`) and the English pages they
/// follow (Blueprint #24).
///
/// Each translation starts with the hash of the English page it was made
/// from:
///
/// ```markdown
/// <!-- source: routing.md sha256:3f2a9c1b7d4e -->
/// ```
///
/// When the English page changes, the hash no longer matches and the
/// translation is stale: `--check` fails until it is updated and stamped
/// again (`dart run tool/docs/generate.dart --stamp=id/routing.md`). Pages
/// without a translation are only reported; the site shows them in English
/// with a notice.

final RegExp _marker = RegExp(
  r'^<!-- source: ([\w./-]+\.md) sha256:([0-9a-f]{12}) -->\r?\n',
);
final RegExp _include = RegExp(
  r'(<!-- include: [^\n]+ -->)\n.*?<!-- /include -->',
  dotAll: true,
);

/// The hash of an English page as a translator sees it: generated code
/// samples (`<!-- include: ... -->` blocks) are left out, so a change in a
/// sample's code does not make the translations stale.
String sourceHash(String english) {
  final text = english
      .replaceAll('\r\n', '\n')
      .replaceAllMapped(_include, (m) => m[1]!);
  return sha256.convert(utf8.encode(text)).toString().substring(0, 12);
}

/// The marker line for a translation of [page] (`routing.md`).
String sourceMarker(String page, String english) =>
    '<!-- source: $page sha256:${sourceHash(english)} -->\n';

/// Headings (`##` and deeper) and code fences of a page, which a
/// translation keeps: the structure, not the words.
({List<int> headings, int fences}) structure(String markdown) {
  final headings = <int>[];
  var fences = 0;
  var inFence = false;
  for (final line in LineSplitter.split(
    markdown.replaceAllMapped(_include, (m) => m[1]!),
  )) {
    if (line.startsWith('```')) {
      fences++;
      inFence = !inFence;
      continue;
    }
    if (inFence) {
      continue;
    }
    final heading = RegExp(r'^(#{2,6}) ').firstMatch(line);
    if (heading != null) {
      headings.add(heading[1]!.length);
    }
  }
  return (headings: headings, fences: fences);
}

/// A problem with the translations: [stale] ones fail the check.
final class TranslationReport {
  final List<String> stale = [];
  final List<String> missing = [];
  final List<String> unstamped = [];
}

/// Checks every page under [guide]`/id/` against its English page.
TranslationReport checkTranslations(Directory guide) {
  final report = TranslationReport();
  final translations = Directory('${guide.path}/id');
  final english = [
    for (final file in guide.listSync().whereType<File>())
      if (file.path.endsWith('.md')) file.uri.pathSegments.last,
  ]..sort();
  for (final page in english) {
    final translation = File('${translations.path}/$page');
    if (!translation.existsSync()) {
      // parity.md is generated from parity.yaml, in English.
      if (page != 'parity.md') {
        report.missing.add(page);
      }
      continue;
    }
    final text = translation.readAsStringSync();
    final source = File('${guide.path}/$page').readAsStringSync();
    final marker = _marker.firstMatch(text);
    if (marker == null) {
      report.unstamped.add('id/$page');
      continue;
    }
    if (marker[1] != page) {
      report.stale.add('id/$page: its marker names ${marker[1]}');
      continue;
    }
    if (marker[2] != sourceHash(source)) {
      report.stale.add(
        'id/$page: $page changed since it was translated; update it, '
        'then run `dart run tool/docs/generate.dart --stamp=id/$page`',
      );
      continue;
    }
    final want = structure(source);
    final got = structure(text.substring(marker.end));
    if (want.headings.join(',') != got.headings.join(',') ||
        want.fences != got.fences) {
      report.stale.add(
        'id/$page: headings or code blocks differ from $page '
        '(${want.headings.length} headings and ${want.fences ~/ 2} code '
        'blocks there, ${got.headings.length} and ${got.fences ~/ 2} here)',
      );
    }
  }
  return report;
}

/// Writes (or refreshes) the source marker of the translation at
/// [guide]`/`[path] (`id/routing.md`); returns the marker.
String stampTranslation(Directory guide, String path) {
  final page = path.replaceFirst(RegExp('^id/'), '');
  final translation = File('${guide.path}/id/$page');
  final source = File('${guide.path}/$page');
  if (!translation.existsSync() || !source.existsSync()) {
    throw ArgumentError('No id/$page or $page under ${guide.path}.');
  }
  final marker = sourceMarker(page, source.readAsStringSync());
  final text = translation.readAsStringSync();
  final body = text.replaceFirst(_marker, '');
  translation.writeAsStringSync('$marker$body');
  return marker.trim();
}
