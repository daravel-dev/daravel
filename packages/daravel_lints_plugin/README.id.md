<!-- source: README.md sha256:a0857a9b21f6 -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_lints_plugin

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_lints_plugin/README.md) · Bahasa Indonesia

Rule [`daravel_lints`](https://pub.dev/packages/daravel_lints) di editor:
plugin analysis server Dart (`analysis_server_plugin`), sehingga temuan
`dartisan lint` muncul saat Anda mengetik, di VS Code, Android Studio dan
IntelliJ, juga di `dart analyze`.

Aktifkan di `analysis_options.yaml` proyek (bagian `plugins:` tingkat atas,
Dart 3.10 ke atas), lalu restart analysis server:

```yaml
plugins:
  daravel_lints_plugin: ^1.27.0
```

Rule yang dijalankan `dartisan lint` secara default langsung menyala. Rule
opt-in (`prefer_sql_identifier`, `string_validation_rule`,
`string_column_name`) dinyalakan lewat namanya:

```yaml
plugins:
  daravel_lints_plugin:
    version: ^1.27.0
    diagnostics:
      prefer_sql_identifier: true
      string_column_name: true
```

`string_column_name` hanya membaca model yang dirujuk sebuah berkas, dari
`lib/app/models` paket berkas itu. Model dibaca sebagaimana dipegang
editor, termasuk perubahan yang belum disimpan, dan hanya dibaca ulang
bila berubah. Model yang tidak diimpor berkas itu tidak ter-resolve,
sehingga editor tidak melaporkannya; `dartisan lint` tetap
melaporkannya.

Temuan dibungkam seperti di `dartisan lint`
(`// daravel-lint-ignore: <rule>` di barisnya) atau dengan `// ignore: <rule>`
dari analyzer. Rule dan pemeriksaannya ada di `daravel_lints`; paket ini
hanya menjalankannya untuk analysis server, yang me-resolve paket ini
terpisah dari aplikasi Anda, sehingga `analyzer` yang di-pin paket ini tidak
pernah masuk ke dependency Anda.

Bila sebuah rule menawarkan fix, editor menawarkannya sebagai quick fix,
termasuk "Fix all ... in file". Sejauh ini ada dua:
- `string_validation_rule` mengganti string dengan rantai `Rules`-nya;
- `string_column_name` mengganti string kolom dengan token model
  (`User.cols.email`).

Editnya berasal dari rule itu sendiri (`LintRule.fixFor` di
`daravel_lints`), sehingga fix hanya ditawarkan bila hasilnya compile dan
artinya tetap sama.
