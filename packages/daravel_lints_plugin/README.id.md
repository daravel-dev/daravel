<!-- source: README.md sha256:be9b1a4eb33d -->
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
opt-in (`prefer_sql_identifier`) dinyalakan lewat namanya:

```yaml
plugins:
  daravel_lints_plugin:
    version: ^1.27.0
    diagnostics:
      prefer_sql_identifier: true
```

Temuan dibungkam seperti di `dartisan lint`
(`// daravel-lint-ignore: <rule>` di barisnya) atau dengan `// ignore: <rule>`
dari analyzer. Rule dan pemeriksaannya ada di `daravel_lints`; paket ini
hanya menjalankannya untuk analysis server, yang me-resolve paket ini
terpisah dari aplikasi Anda, sehingga `analyzer` yang di-pin paket ini tidak
pernah masuk ke dependency Anda.
