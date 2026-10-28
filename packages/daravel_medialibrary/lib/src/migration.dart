import 'package:daravel/daravel.dart';

/// spatie/laravel-medialibrary v11's `create_media_table` migration, with
/// its column order and index names.
///
/// It creates nothing when the table exists: a Laravel application that
/// ran Spatie's migration owns it.
final class CreateMediaTable extends Migration {
  const CreateMediaTable();

  @override
  String get name => '2026_10_28_000001_create_media_table';

  @override
  Future<void> up(SchemaBuilder schema) async {
    if (await schema.hasTable('media')) {
      return;
    }
    await schema.create('media', (table) {
      table.id();
      // morphs('model')
      table.string('model_type');
      table.unsignedBigInteger('model_id');
      table.index(['model_type', 'model_id']);
      table.uuid('uuid').nullable().unique();
      table.string('collection_name');
      table.string('name');
      table.string('file_name');
      table.string('mime_type').nullable();
      table.string('disk');
      table.string('conversions_disk').nullable();
      table.unsignedBigInteger('size');
      table.json('manipulations');
      table.json('custom_properties');
      table.json('generated_conversions');
      table.json('responsive_images');
      table.unsignedInteger('order_column').nullable().index();
      table.timestamp('created_at').nullable();
      table.timestamp('updated_at').nullable();
    });
  }

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('media');
}
