### Changed

- `daravel_mysql` moves to `mysql_dart` ^4.0.1 (B4): TLS connections can verify the server certificate, connect, TLS and authentication are bounded by the connect timeout, and the pool no longer exceeds `maxConnections` or leaves waiters hanging. `DB_SSLMODE` reads as for PostgreSQL (libpq names) and MySQL's `--ssl-mode` names: `disable`/`DISABLED`; `require`/`REQUIRED`/`PREFERRED` encrypt without checking the certificate (as before); `verify-full`, `verify-ca`, `VERIFY_IDENTITY`, `VERIFY_CA` check the certificate and the host name. An unknown value is read as `require` and reported once at boot.

### Added

- MySQL and MariaDB: `DB_SSLROOTCERT` (or Laravel's `MYSQL_ATTR_SSL_CA`) names the CA that signed the server certificate; given without `DB_SSLMODE` it verifies the server, as PDO MySQL does. `MySqlDriver` takes `verifyServerCertificate`, `securityContext` and `sslCa`; `MySqlDriver.sslOptions` shows how a mode maps.

### Upgrade notes

- `MySqlDriver(secure: true)` built directly now verifies the server certificate by default (`verifyServerCertificate: true`, as `mysql_dart` 4). Pass `verifyServerCertificate: false` for a server with the certificate MySQL or MariaDB generates on first start, or give its CA through `securityContext`/`sslCa`. `DB_SSLMODE=require` through `fromConfig` keeps its old behaviour (encrypted, not checked); prefer `verify-full` with `DB_SSLROOTCERT` in production.
- `DB_SSLMODE=require` with `DB_SSLROOTCERT` or `MYSQL_ATTR_SSL_CA` set now verifies the server against that CA, as libpq and the MySQL client do.
- `config('database.connections.mysql.sslmode')` is `null` when `DB_SSLMODE` is unset (it was `'disable'`); the connection still has no TLS.
