/// A file about to be added, as [MediaCollection.acceptsFile] sees it
/// (Spatie's `File`).
final class PendingFile {
  /// A file about to be added.
  const PendingFile({
    required this.name,
    required this.size,
    required this.mimeType,
  });

  /// The file name after sanitizing.
  final String name;

  /// Its size in bytes.
  final int size;

  /// Its MIME type.
  final String mimeType;
}

/// A media collection (Spatie's `MediaCollection`), declared in
/// `registerMediaCollections()`.
final class MediaCollection {
  /// A collection named [name].
  MediaCollection(this.name);

  /// The collection's name.
  final String name;

  /// The disk of its files; the default one when null.
  String? diskName;

  /// The disk of its conversions; the files' disk when null.
  String? conversionsDiskName;

  /// How many files the collection keeps, the newest; unlimited when null.
  int? collectionSizeLimit;

  bool Function(PendingFile file)? _acceptsFile;
  final List<String> _acceptsMimeTypes = [];

  /// The URL and path [InteractsWithMedia.getFirstMediaUrl] and
  /// `getFirstMediaPath` return when the collection is empty, per
  /// conversion (`''` for the file itself).
  final Map<String, String> fallbackUrls = {};

  /// The paths of files shown while the collection is empty, by conversion.
  final Map<String, String> fallbackPaths = {};

  /// Stores the files on [disk].
  MediaCollection useDisk(String disk) {
    diskName = disk;
    return this;
  }

  /// Stores the conversions on [disk].
  MediaCollection storeConversionsOnDisk(String disk) {
    conversionsDiskName = disk;
    return this;
  }

  /// Keeps one file: adding another deletes the previous one.
  MediaCollection singleFile() => onlyKeepLatest(1);

  /// Keeps the newest [count] files.
  MediaCollection onlyKeepLatest(int count) {
    collectionSizeLimit = count;
    return this;
  }

  /// Refuses files [accepts] returns false for.
  MediaCollection acceptsFile(bool Function(PendingFile file) accepts) {
    _acceptsFile = accepts;
    return this;
  }

  /// Refuses files whose detected MIME type is not one of [mimeTypes].
  MediaCollection acceptsMimeTypes(List<String> mimeTypes) {
    _acceptsMimeTypes.addAll(mimeTypes);
    return this;
  }

  /// The URL used while the collection is empty.
  MediaCollection useFallbackUrl(String url, [String conversion = '']) {
    fallbackUrls[conversion] = url;
    return this;
  }

  /// The path used while the collection is empty.
  MediaCollection useFallbackPath(String path, [String conversion = '']) {
    fallbackPaths[conversion] = path;
    return this;
  }

  /// Whether [file] may join the collection.
  bool accepts(PendingFile file) =>
      (_acceptsFile?.call(file) ?? true) &&
      (_acceptsMimeTypes.isEmpty || _acceptsMimeTypes.contains(file.mimeType));

  /// Whether any MIME type is accepted.
  bool get acceptsAnyMimeType => _acceptsMimeTypes.isEmpty;
}
