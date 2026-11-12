<!-- source: README.md sha256:6306a30b972f -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_scout

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_scout/README.md) · Bahasa Indonesia

Laravel Scout untuk [Daravel](https://daravel.dev), dengan engine database:
pencarian berjalan di tabel model itu sendiri dengan `LIKE` dan full text search,
serta `semantic()` dan `hybrid()` mencari berdasarkan makna di PostgreSQL dengan
pgvector atau di MariaDB.

```dart
final class Post extends Model with Searchable {
  // ...
  @override
  Map<String, Object?> toSearchableArray() => {'title': null, 'body': null};
}

final posts = await Scout.search(Post.definition, 'laravel').take(10).get();
```

Lihat [panduannya](https://daravel.dev/id/scout.html).

## Rerank

`hybrid(rerank: true)` mengurutkan 1 000 model hasil fusion pertama berdasarkan
cosine similarity terhadap vector query, dihitung di Dart dengan `Float32x4`
(empat lane sekaligus, loop skalar untuk sisanya) pada vector yang sudah
dikembalikan database bersama modelnya. Tidak ada query tambahan dan tidak ada
yang disimpan di memori, jadi biarkan kolom embedding tetap ter-select di
`constrain()`; model tanpa vector menyusul dalam urutan fusion.

Lane `Float32x4` menjumlah dalam float32 dan loop skalar dalam double, jadi
sebuah skor bisa berbeda dari cosine presisi double sampai sekitar 1e-5 (3 072
dimensi). Dua model yang skornya lebih dekat dari itu adalah hampir-seri yang
urutannya tidak dijamin; skor yang sama persis mempertahankan urutan fusion.

`bench/bin/scout_rerank.dart`, 1 000 kandidat, diukur pada 2026-11-06
(Dart 3.13.4 AOT, Windows x64):

| Dimensi | Cosine skalar | Cosine `Float32x4` | Rerank dari byte MariaDB | Rerank dari pgvector biner | Rerank dari teks pgvector |
| --: | --: | --: | --: | --: | --: |
| 1 536 | 3,5 ms | 1,1 ms (3,2×) | 3,0 ms | 12 ms | 115 ms |
| 3 072 | 7,0 ms | 2,1 ms (3,3×) | 5,1 ms | 22 ms | 224 ms |

Kolom cosine menilai 1 000 vector yang sudah berupa `Float32List`; kolom rerank
menambahkan pembacaan nilai dari driver, yang lebih mahal daripada cosine-nya
sendiri, terutama untuk bentuk teks pgvector.
