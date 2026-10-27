/// The few XML shapes S3 answers with (`ListBucketResult`, `Error`,
/// `DeleteResult`, `InitiateMultipartUploadResult`) are flat, so a small
/// tag reader replaces an XML dependency.
library;

/// The text of every `<tag>…</tag>` in [xml], in order and unescaped.
List<String> xmlValues(String xml, String tag) => [
  for (final match in RegExp(
    '<$tag(?:\\s[^>]*)?>([\\s\\S]*?)</$tag>',
  ).allMatches(xml))
    xmlUnescape(match.group(1)!),
];

/// The first `<tag>` of [xml], or `null`.
String? xmlValue(String xml, String tag) {
  final values = xmlValues(xml, tag);
  return values.isEmpty ? null : values.first;
}

/// The raw inner XML of every `<tag>…</tag>` block (for repeated groups
/// such as `<Contents>` or `<Error>`), not unescaped.
List<String> xmlBlocks(String xml, String tag) => [
  for (final match in RegExp(
    '<$tag(?:\\s[^>]*)?>([\\s\\S]*?)</$tag>',
  ).allMatches(xml))
    match.group(1)!,
];

/// Escapes text for an element body.
String xmlEscape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// Resolves the five predefined entities and numeric references.
String xmlUnescape(String text) => text.replaceAllMapped(
  RegExp(r'&(#x[0-9A-Fa-f]+|#[0-9]+|amp|lt|gt|quot|apos);'),
  (match) => switch (match.group(1)!) {
    'amp' => '&',
    'lt' => '<',
    'gt' => '>',
    'quot' => '"',
    'apos' => "'",
    final ref when ref.startsWith('#x') => String.fromCharCode(
      int.parse(ref.substring(2), radix: 16),
    ),
    final ref => String.fromCharCode(int.parse(ref.substring(1))),
  },
);
