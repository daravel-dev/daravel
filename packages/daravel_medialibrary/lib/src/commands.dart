import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';

import 'media.dart';
import 'media_library.dart';

/// The `media:*` commands, for `bootstrap/commands.dart`.
const List<CommandFactory> mediaLibraryCommands = [
  MediaRegenerateCommand.new,
  MediaCleanCommand.new,
];

/// `media:regenerate [modelType] [--ids=1,2] [--only=thumb] [--only-missing]`
/// (Spatie's): generates the conversions again, here and now, after their
/// definitions changed.
final class MediaRegenerateCommand extends DaravelCommand {
  MediaRegenerateCommand(super.createApp) {
    argParser
      ..addOption('ids', help: 'Only these media ids, comma separated.')
      ..addOption('only', help: 'Only these conversions, comma separated.')
      ..addFlag(
        'only-missing',
        negatable: false,
        help: 'Skip conversions that were generated and still exist.',
      );
  }

  @override
  String get name => 'media:regenerate';

  @override
  String get description => 'Regenerate the derived images of media.';

  @override
  Future<int> run() => withApp((app) async {
    final results = argResults!;
    List<String>? list(String option) => (results[option] as String?)
        ?.split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    var query = Media.query().orderBy('id');
    final type = results.rest.firstOrNull;
    if (type != null) {
      query = query.where('model_type', type);
    }
    final ids = list('ids');
    if (ids != null) {
      query = query.whereIn('id', ids.map(int.parse).toList());
    }
    var done = 0;
    var failed = 0;
    for (final media in await query.get()) {
      try {
        await MediaLibrary.performConversions(
          media,
          only: list('only'),
          onlyMissing: results['only-missing'] as bool,
          now: true,
        );
        done++;
      } on Object catch (error) {
        failed++;
        stderr.writeln('Media ${media.id} (${media.fileName}): $error');
      }
    }
    stdout.writeln(
      'Regenerated $done media${failed > 0 ? ', $failed failed' : ''}.',
    );
    return failed > 0 ? 1 : 0;
  });
}

/// `media:clean [--dry-run] [--disk=public] [--force]` (Spatie's): deletes
/// conversion files no conversion defines any more, and media directories
/// whose row is gone.
final class MediaCleanCommand extends DaravelCommand {
  MediaCleanCommand(super.createApp) {
    argParser
      ..addOption('disk', help: 'The disk to clean; MEDIA_DISK by default.')
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'List what would be deleted.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Required when APP_ENV=production.',
      );
  }

  @override
  String get name => 'media:clean';

  @override
  String get description =>
      'Delete obsolete conversions and files without a media row.';

  @override
  Future<int> run() => withApp((app) async {
    final results = argResults!;
    final dryRun = results['dry-run'] as bool;
    if (!dryRun &&
        app.config.section<AppConfig>().isProduction &&
        !(results['force'] as bool)) {
      stderr.writeln(
        'media:clean deletes files; pass --force to run it in production.',
      );
      return 1;
    }
    final diskName = results['disk'] as String? ?? MediaLibrary.config.diskName;
    final disk = Storage.disk(diskName);
    var deleted = 0;

    Future<void> remove(String path, {bool directory = false}) async {
      deleted++;
      stdout.writeln('${dryRun ? 'Would delete' : 'Deleted'} $path');
      if (!dryRun) {
        await (directory ? disk.deleteDirectory(path) : disk.delete(path));
      }
    }

    // Conversions no longer defined, of media on this disk.
    final media = await Media.query()
        .where('conversions_disk', diskName)
        .orderBy('id')
        .get();
    for (final item in media) {
      final owner = await MediaLibrary.ownerOf(item);
      if (owner == null) {
        continue;
      }
      final expected = {
        for (final conversion in MediaLibrary.conversionsOf(owner, item))
          if (conversion.shouldBePerformedOn(item.collectionName))
            item.path(conversion.name),
      };
      for (final file in await disk.files('${item.directory}/conversions')) {
        if (!expected.contains(file)) {
          await remove(file);
        }
      }
    }

    // Directories named after a media id that no row has any more.
    final prefix = MediaLibrary.config.prefix;
    final ids = {
      for (final row in await Media.query().where('disk', diskName).get())
        row.id,
      for (final row in media) row.id,
    };
    for (final directory in await disk.directories(prefix)) {
      final name = directory.split('/').last;
      final id = int.tryParse(name);
      if (id != null && !ids.contains(id)) {
        await remove(directory, directory: true);
      }
    }
    stdout.writeln('${dryRun ? 'Would delete' : 'Deleted'} $deleted path(s).');
    return 0;
  });
}
