<!-- source: README.md sha256:eda07e9b1cf3 -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# dartisan_cli

[English](https://github.com/daravel-dev/daravel/blob/main/packages/dartisan_cli/README.md) · Bahasa Indonesia

`dartisan`, command-line interface untuk
[Daravel](https://pub.dev/packages/daravel), framework backend untuk Dart
yang terinspirasi Laravel dan berjalan native secara AOT.

```bash
dart pub global activate dartisan_cli
dartisan new blog                  # template api: auth, user, token, test, CI
dartisan new tiny --template=minimal
```

Di dalam proyek, CLI milik proyek (`bin/dartisan.dart`) mengenal aplikasi
Anda:

| Kelompok | Command |
| :-- | :-- |
| Proyek | `about`, `doctor [--production]`, `key:generate`, `stub:publish`, `lint`, `cache:clear`, `storage:link`, `env:encrypt`, `env:decrypt`, `env:obfuscate`, `adopt <laravel-path>`, `down`, `up`, `tinker "<expr>"`, `mcp:serve`, `mcp:install` |
| Serve, test & build | `serve [--watch] [--isolates=N] [--embed-queue] [--embed-scheduler]`, `test [--conformance] [--security] [--coverage]`, `build [--with-cli] [--docker] [--no-sqlite]`, `route:list`, `openapi:generate`, `client:flutter`, `coordinator:stats` |
| Database | `migrate`, `migrate:status`, `migrate:rollback`, `migrate:reset`, `migrate:fresh`, `db:seed`, `model:sync`, `model:show`, `db:show`, `db:table`, `db:install`, `db:transfer`, `db:backup`, `daragic:export` |
| Generator | `make:model`, `make:migration`, `make:controller`, `make:request`, `make:middleware`, `make:job`, `make:policy`, `make:event`, `make:listener`, `make:resource`, `make:rule`, `make:mail`, `make:notification`, `make:observer`, `make:provider`, `make:command`, `make:seeder`, `make:factory`, `make:test` |
| Queue & jadwal | `queue:work`, `queue:failed`, `queue:retry`, `queue:forget`, `queue:flush`, `queue:clear`, `queue:pause`, `queue:continue`, `queue:restart`, `schedule:work`, `schedule:run`, `schedule:list` |

`serve --watch` melakukan hot reload lewat Dart VM service; `build`
menjalankan `dart build cli` dan menghasilkan bundle native dengan SQLite
di dalamnya. `openapi:generate` mendokumentasikan body request dan respons
dari rule dan schema yang dideklarasikan di route (`.validates(...)`,
`.returns(...)`), dan `doctor --production` adalah pengecekan pra-jalan
untuk entrypoint container. `client:flutter` menghasilkan client Dart/Flutter
bertipe dari route, dan `mcp:serve` memberi agen AI coding akses ke route,
skema, model, dan log proyek. `dartisan --version` mencetak versinya.

Untuk menanamkan runner di entrypoint Anda sendiri, lihat
[`example/main.dart`](example/main.dart).
Dokumentasi: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/id/dartisan.md>.

## Lisensi dan merek dagang

MIT. "Laravel" adalah merek dagang Laravel Holdings Inc.; "Dart" dan
"Flutter" adalah merek dagang Google LLC. Daravel adalah proyek independen,
tidak berafiliasi dengan maupun didukung oleh keduanya. Kode yang dihasilkan
`dartisan` adalah milik Anda.
