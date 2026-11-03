<!-- source: scout.md sha256:a045738a8244 -->
# Pencarian (daravel_scout)

`daravel_scout` adalah engine `database` dari Laravel Scout: pencarian berjalan di
tabel model itu sendiri, tanpa indeks yang harus disinkronkan. Di PostgreSQL dengan
pgvector, atau di MariaDB 11.7 atau lebih baru, paket ini juga bisa mencari
berdasarkan makna.

```bash
dart pub add daravel_scout
```

## Mencari

Tambahkan `Searchable` ke model dan sebutkan kolom yang dicari. Model baru belum
punya attribute, jadi `toSearchableArray` harus mencantumkannya, seperti di Scout.

```dart
import 'package:daravel_scout/daravel_scout.dart';

final class Post extends Model with Searchable {
  // ... definition dan accessor

  @override
  Map<String, Object?> toSearchableArray() => {'title': null, 'body': null};

  @override
  List<String> get searchUsingFullText => const ['body'];

  @override
  List<String> get searchUsingPrefix => const ['title'];
}

final posts = await Scout.search(Post.definition, 'laravel')
    .where('published', true)
    .take(10)
    .get();
```

Setiap kolom dicocokkan dengan `LIKE` (`ILIKE` di PostgreSQL), dan `query%` untuk
kolom prefix. Query berupa angka juga dicocokkan dengan key. Hasil diurutkan dari
yang terbaru; dengan kolom full text di PostgreSQL, berdasarkan relevansi. `whereIn`,
`whereNotIn`, `orderBy`, `first`, `keys`, `paginate`, dan `constrain` untuk menambah
query database bekerja seperti di Scout.

`searchUsingFullText` adalah `#[SearchUsingFullText]` di Scout: `tsvector` di
PostgreSQL dan `MATCH` di MySQL atau MariaDB. `fullTextOptions` mengatur `language`
dan `mode`. SQLite tidak punya full text search, jadi kolom full text melempar error
di sana.

## Mencari berdasarkan makna

Tentukan kolom vector dan apa yang di-embed, lalu berikan Scout fungsi yang mengubah
teks menjadi vector. Scout memakai `laravel/ai` untuk itu; di sini Anda yang
memasangnya.

```dart
@override
String? get searchableEmbeddingColumn => 'embedding';

@override
Object? toSearchableEmbedding() => body;   // atau List<num> yang sudah ada

Scout.embedder = (texts) => myEmbeddingService.embed(texts);
await Scout.makeSearchable(posts);         // menulis vector-nya

final similar = await Scout.search(Post.definition, 'deploying apps')
    .semantic(0.7)
    .get();

final both = await Scout.search(Post.definition, 'deploying apps')
    .hybrid(textWeight: 1, semanticWeight: 2)
    .get();
```

`semantic` menyisakan baris yang setidaknya semirip itu (default 0,6), yang terdekat
lebih dulu. `hybrid` menggabungkan peringkat teks dan makna dengan reciprocal rank
fusion, seperti Scout. Keduanya tidak bisa digabung dengan `orderBy`. Kolomnya
berasal dari `table.vector` ([Database](database.md#kolom-vector)); di SQLite
keduanya melempar error.

## Padanan Laravel

Bagian lain dari Laravel yang ikut didukung, beserta API yang bisa dicari di pub.dev.

| Laravel | Daravel | API | Catatan |
| :-- | :-- | :-- | :-- |
| `use Searchable; public function toSearchableArray()` | `with Searchable; toSearchableArray()` | `Searchable.toSearchableArray` | Hanya engine database. |
| `#[SearchUsingFullText(['body'])]` | `List<String> get searchUsingFullText => ['body']` | `Searchable.searchUsingFullText` |  |
