/// A file about to be added, as [MediaCollection.acceptsFile] sees it
/// (Spatie's `File`).
final class PendingFile {
  const PendingFile({
    required this.name,
    required this.size,
    required this.mimeType,
  });

  /// The file name after sanitizing.
  final String name;
  final int size;
  final String mimeType;
}

/// A media collection (Spatie's `MediaCollection`), declared in
/// `registerMediaCollections()`.
final class MediaCollection {
  MediaCollection(this.name);

  final String name;

  String? diskName;
  String? conversionsDiskName;

  /// How many files the collection keeps, the newest; unlimited when null.
  int? collectionSizeLimit;

  bool Function(PendingFile file)? _acceptsFile;
  final List<String> _acceptsMimeTypes = [];

  /// The URL and path [InteractsWithMedia.getFirstMediaUrl] and
  /// `getFirstMediaPath` return when the collection is empty, per
  /// conversion (`''` for the file itself).
  final Map<String, String> fallbackUrls = {};
  final Map<String, String> fallbackPaths = {};

  MediaCollection useDisk(String disk) {
    diskName = disk;
    return this;
  }

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

  MediaCollection useFallbackUrl(String url, [String conversion = '']) {
    fallbackUrls[conversion] = url;
    return this;
  }

  MediaCollection useFallbackPath(String path, [String conversion = '']) {
    fallbackPaths[conversion] = path;
    return this;
  }

  /// Whether [file] may join the collection.
  bool accepts(PendingFile file) =>
      (_acceptsFile?.call(file) ?? true) &&
      (_acceptsMimeTypes.isEmpty || _acceptsMimeTypes.contains(file.mimeType));

  bool get acceptsAnyMimeType => _acceptsMimeTypes.isEmpty;
}
