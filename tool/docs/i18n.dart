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

/// `<!-- release -->1.12.0<!-- /release -->` in the READMEs: the release
/// number, written by `generate.dart` from `daravelVersion`.
final RegExp releaseMarker = RegExp(r'<!-- release -->[^<]*<!-- /release -->');

/// The hash of an English page as a translator sees it: generated code
/// samples (`<!-- include: ... -->` blocks) and the release number are left
/// out, so a new sample or release does not make the translations stale.
String sourceHash(String english) {
  final text = english
      .replaceAll('\r\n', '\n')
      .replaceAllMapped(_include, (m) => m[1]!)
      .replaceAll(releaseMarker, '<!-- release --><!-- /release -->');
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

/// Checks every page under [guide]`/id/` against its English page, and
/// each `README.id.md` (the repository's and the packages') against its
/// `README.md`.
TranslationReport checkTranslations(Directory guide) {
  final report = TranslationReport();
  final english = [
    for (final file in guide.listSync().whereType<File>())
      if (file.path.endsWith('.md')) file.uri.pathSegments.last,
  ]..sort();
  for (final page in english) {
    // parity.md is generated from parity.yaml, in English.
    if (page == 'parity.md') {
      continue;
    }
    _checkPair(
      report,
      source: File('${guide.path}/$page'),
      translation: File('${guide.path}/id/$page'),
      label: 'id/$page',
    );
  }
  for (final readme in readmes()) {
    _checkPair(
      report,
      source: File(readme),
      translation: File(readme.replaceFirst('README.md', 'README.id.md')),
      label: readme.replaceFirst('README.md', 'README.id.md'),
    );
  }
  return report;
}

/// The English READMEs that have an Indonesian counterpart: the
/// repository's and every package's, relative to the repository root.
List<String> readmes() => [
  'README.md',
  for (final dir in Directory('packages').listSync().whereType<Directory>())
    if (File('${dir.path}/README.md').existsSync())
      '${dir.path.replaceAll(r'\', '/')}/README.md',
]..sort();

void _checkPair(
  TranslationReport report, {
  required File source,
  required File translation,
  required String label,
}) {
  final page = source.uri.pathSegments.last;
  if (!translation.existsSync()) {
    report.missing.add(label);
    return;
  }
  final text = translation.readAsStringSync();
  final english = source.readAsStringSync();
  final marker = _marker.firstMatch(text);
  if (marker == null) {
    report.unstamped.add(label);
    return;
  }
  if (marker[1] != page) {
    report.stale.add('$label: its marker names ${marker[1]}');
    return;
  }
  if (marker[2] != sourceHash(english)) {
    report.stale.add(
      '$label: ${source.path.replaceAll(r'\', '/')} changed since it was '
      'translated; update it, then run '
      '`dart run tool/docs/generate.dart --stamp=$label`',
    );
    return;
  }
  final want = structure(english);
  final got = structure(text.substring(marker.end));
  if (want.headings.join(',') != got.headings.join(',') ||
      want.fences != got.fences) {
    report.stale.add(
      '$label: headings or code blocks differ from $page '
      '(${want.headings.length} headings and ${want.fences ~/ 2} code '
      'blocks there, ${got.headings.length} and ${got.fences ~/ 2} here)',
    );
  }
}

/// Writes (or refreshes) the source marker of a translation and returns
/// it: a guide page (`id/routing.md`, under [guide]) or a README
/// (`README.id.md`, `packages/daravel/README.id.md`).
String stampTranslation(Directory guide, String path) {
  final File translation;
  final File source;
  if (path.endsWith('README.id.md')) {
    translation = File(path);
    source = File(path.replaceFirst('README.id.md', 'README.md'));
  } else {
    final page = path.replaceFirst(RegExp('^id/'), '');
    translation = File('${guide.path}/id/$page');
    source = File('${guide.path}/$page');
  }
  if (!translation.existsSync() || !source.existsSync()) {
    throw ArgumentError('No ${translation.path} or ${source.path}.');
  }
  final page = source.uri.pathSegments.last;
  final marker = sourceMarker(page, source.readAsStringSync());
  final text = translation.readAsStringSync();
  final body = text.replaceFirst(_marker, '');
  translation.writeAsStringSync('$marker$body');
  return marker.trim();
}
