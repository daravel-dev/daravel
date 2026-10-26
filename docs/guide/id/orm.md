<!-- source: orm.md sha256:d44671bf77b6 -->
# ORM

Model mengikuti API Eloquent. Karena Dart tidak punya property ajaib, setiap
model punya `ModelDefinition` statis yang menjelaskan tabel, atribut, dan
relasinya; [Database](database.md) menunjukkan model lengkap dan query
builder-nya.

## Definisi

```dart
final class User extends Model {
  static final ModelDefinition<User> definition = ModelDefinition<User>(
    table: 'users',
    factory: User.new,
    fillable: ['name', 'email', 'password'],
    hidden: ['password', 'remember_token'],
    casts: {'email_verified_at': Cast.dateTime, 'settings': Cast.json},
    softDeletes: true,
    relations: {
      'posts': () => HasMany<Post>(() => Post.definition, foreignKey: 'user_id'),
      'roles': () => BelongsToMany<Role>(
        () => Role.definition,
        pivotTable: 'role_user',
        foreignPivotKey: 'user_id',
        relatedPivotKey: 'role_id',
      ),
    },
  );

  @override
  ModelDefinition<User> get modelDefinition => User.definition;
}
```

Static-nya bernama `definition` dan getter instance-nya `modelDefinition`,
karena Dart melarang member static dan instance dengan nama yang sama.
Pertahankan tipe eksplisit `ModelDefinition<User>` dan tulis relasi sebagai
fungsi: tanpa itu, model yang saling merujuk akan membentuk siklus inferensi
tipe.

Opsi lain: `primaryKey`, `keyType` (auto-increment, UUID, ULID, atau
string), `connection`, `guarded`, `visible`, `appends`, `timestamps` dan
nama kolom `createdAt` / `updatedAt` / `deletedAt`, `perPage`, `touches`,
`withRelations` (`$with` dari Eloquent), dan `morphClass` (nama kelas
Laravel yang disimpan di kolom polimorfik, `App\Models\User` secara
default).

## Atribut

Cast: `Cast.integer`, `decimal`, `boolean`, `string`, `dateTime`, `date`,
`json`, `Cast.enumeration(MyEnum.values)`, dan `Cast.custom(...)`.
`accessors:` dan `mutators:` menggantikan method atribut dari Laravel, dan
`dartisan model:sync` menulis getter dan setter bertipe dari tabel, sehingga
`user.email` adalah `String` yang dicek compiler.

## Registry model

`bootstrap/models.dart` mencantumkan model aplikasi, seperti registry lain
mencantumkan migrasi dan job (Daravel tidak menemukan apa pun lewat
reflection):

```dart
final List<ModelDefinition<Model>> models = <ModelDefinition<Model>>[
  // <dartisan:entries>
  User.definition,
  Post.definition,
  // </dartisan:entries>
];
```

`createApp` meneruskannya ke `.withModels(models)`, dan `dartisan make:model`
menambahkan model baru ke dalamnya. `dartisan model:show Post [--json]`
(`model:show` dari Laravel 11) mencetak tabel model, atributnya beserta
tipe, cast, serta tanda fillable dan hidden, dan relasinya;
`dartisan mcp:serve` memberi agen AI data yang sama. Begitu file ini ada,
`dartisan lint` melaporkan model di `lib/app/models` yang belum
dicantumkan.

Proyek yang dibuat sebelum 1.3 bisa menambahkan file ini secara manual
(salin blok di atas, satu entri per model) beserta pemanggilan
`.withModels(models)`; sampai saat itu, semua hal lain tetap berjalan.

## Relasi

`HasOne`, `HasMany`, `BelongsTo`, `BelongsToMany` (dengan `withPivot` dan
`withTimestamps`), `HasManyThrough`, `HasOneThrough`, serta relasi
polimorfik `MorphOne`, `MorphMany`, `MorphTo`, `MorphToMany`, dan
`MorphedByMany` (lihat [Relasi polimorfik](#relasi-polimorfik)).

```dart
final users = await User.query()
    .with_(['posts', 'roles'])      // eager loading; `with` dicadangkan di Dart
    .withCount('posts')
    .whereHas('posts', (q) => q.where('published', true))
    .paginate();

final posts = users.items.first.related<List<Post>>('posts');
final drafts = await user.relatedQuery<Post>('posts').where('published', false).get();

await user.attach('roles', [1, 2]);
await user.sync('roles', [2, 3]);
await user.detach('roles', [3]);
```

`load` dan `loadMissing` memuat relasi ke model yang sudah Anda punya.
`Model.preventLazyLoading` mengubah relasi yang belum dimuat menjadi error,
sehingga query N+1 tertangkap di test.

### Query keberadaan bersarang

`whereHas`, `orWhereHas`, `has`, `whereDoesntHave`, `orWhereDoesntHave`,
`doesntHave`, dan `withWhereHas` menerima relasi bersarang, sedalam apa pun.
Setiap level menjadi `EXISTS` di dalam level sebelumnya, batasannya berlaku
pada level terakhir, dan soft delete serta global scope berlaku di setiap
level:

```dart
// User yang punya setidaknya satu komentar yang disetujui di salah satu post-nya.
final users = await User.query()
    .whereHas('posts.comments', (q) => q.where('approved', true))
    .get();
```

Relasi ke model yang sama (`Category` dengan `parent` dan `children`, user
yang mengikuti user) juga bisa: tabel di dalamnya mendapat alias, seperti
`laravel_reserved_N` dari Laravel, sehingga `whereHas('children')`
membandingkan child dengan parent di luarnya, bukan dengan dirinya sendiri.

### Agregat relasi

`withCount`, `withSum`, `withAvg`, `withMin`, `withMax`, dan `withExists`
menambahkan satu kolom per relasi, dengan nama seperti di Laravel
(`posts_count`, `orders_sum_total`, `orders_exists`);
`'orders as paid_orders'` memilih namanya, dan map menambahkan batasan:

```dart
final users = await User.query()
    .withCount('posts')
    .withSum('orders', 'total')
    .withMax({'orders': (ModelQuery<Model> q) => q.where('paid', true)}, 'total')
    .withExists('orders')
    .get();
```

`*_exists` terbaca sebagai `bool`. Jumlah dan rata-rata dikembalikan apa
adanya dari driver: angka di SQLite, string untuk hasil `DECIMAL`/`numeric`
di MySQL dan PostgreSQL, sama seperti PDO di Laravel.

## Relasi polimorfik

Relasi polimorfik memungkinkan satu tabel dimiliki beberapa model: komentar
pada post dan video, gambar milik user dan produk, tag yang dipakai bersama
oleh semuanya. Baris child menyimpan tipe pemiliknya di `{name}_type` dan
key-nya di `{name}_id`, persis seperti Laravel menyimpannya, sehingga kedua
framework bisa membaca baris yang sama.

```dart
// Migrasi
schema.create('comments', (table) {
  table.id();
  table.morphs('commentable'); // commentable_type, commentable_id + index
  table.text('body');
});

// Post (dan Video, dengan cara yang sama)
'comments': () => MorphMany<Comment>(() => Comment.definition, morphName: 'commentable'),
'image': () => MorphOne<Image>(() => Image.definition, morphName: 'imageable'),
'tags': () => MorphToMany<Tag>(() => Tag.definition, morphName: 'taggable', relatedPivotKey: 'tag_id'),

// Comment: pemiliknya, sebuah Post atau Video
'commentable': () => MorphTo(types: [() => Post.definition, () => Video.definition]),

// Tag: kebalikan dari morphToMany
'posts': () => MorphedByMany<Post>(() => Post.definition, morphName: 'taggable', foreignPivotKey: 'tag_id'),
```

- `MorphMany` / `MorphOne` bekerja seperti `HasMany` / `HasOne`, disaring
  berdasarkan tipe pemilik: eager loading, `relatedQuery`, `whereHas`,
  `withCount`, dan `create(parent, db, attributes)`, yang mengisi kedua
  kolom morph.
- `MorphTo` memuat pemilik setiap baris, satu query per tipe yang tersimpan
  saat eager loading, dan relasi bersarang
  (`with_(['commentable.author'])`) dimuat per tipe. `associate(child,
  owner)` dan `dissociate(child)` mengisi kolomnya;
  `touches: ['commentable']` memperbarui timestamp pemiliknya.
- `MorphToMany` / `MorphedByMany` bekerja seperti `BelongsToMany` (`attach`,
  `detach`, `sync`, `withPivot`) dengan kolom tipe di tabel pivot
  (`{name}s` secara default, di sini `taggables`).
- `whereHasMorph('commentable', [Post.definition], (q, type) => ...)`,
  `whereDoesntHaveMorph`, dan bentuk `orWhere*`-nya meng-query pemiliknya.
  Pada `MorphTo`, `whereHas` dan `whereDoesntHave` mengecek setiap tipe yang
  dikenal relasi itu.

Tipe yang disimpan adalah `morphClass` milik model (`App\Models\Post` secara
default, seperti nama kelas di Laravel). Daftarkan alias seperti di
Laravel; baris yang masih menyimpan nama kelas tetap bisa di-resolve:

```dart
Relation.morphMap({'post': () => Post.definition, 'video': () => Video.definition});
Relation.enforceMorphMap({...}); // setiap model polimorfik lalu wajib punya alias
```

Dart tidak punya reflection, jadi `MorphTo` tidak bisa mengubah nama kelas
yang tersimpan menjadi model dengan sendirinya: setiap kemungkinan pemilik
harus dicantumkan di `types:` atau di morph map. Karena alasan yang sama,
`whereHas` pada `MorphTo` mengecek tipe-tipe yang dicantumkan, sedangkan
Laravel membaca tipe yang berbeda-beda dari tabelnya.

## Scope, soft delete, dan event

- Local scope (`scopes:`) dipanggil dengan `query.scope('published')`;
  `globalScopes:` berlaku untuk setiap query.
- Dengan `softDeletes: true`, `delete()` mengisi `deleted_at`, query
  melewati baris yang terhapus, dan `withTrashed()`, `onlyTrashed()`,
  `restore()`, serta `forceDelete()` bekerja seperti di Laravel.
- Observer (`observers:`) menerima `creating`, `created`, `updating`,
  `updated`, `saving`, `saved`, `deleting`, `deleted`, `restoring`,
  `restored`, dan event force-delete; mengembalikan `false` dari hook
  `*ing` membatalkan operasinya.
