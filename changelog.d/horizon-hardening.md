### Changed

- `daravel_horizon` dashboard (HZ-1): every request is authorized after its middleware, as Laravel Horizon's `Authenticate` middleware does. `APP_ENV=local` is open; otherwise `HorizonDashboard.auth(callback)` decides (Laravel's `Horizon::auth`), or without it the `viewHorizon` gate; anything else is a 403, for the page and every API route, mutations included. Middleware is no longer taken as protection, and `APP_ENV=testing` is no longer open. A callback or gate that throws denies the request and is logged. Without `middleware:`, `withHorizon()` uses the application's `web` group when it registers one (`withSession()`), else none; a `middleware:` entry the application does not register stops the boot with a `ConfigException` naming `withSession()` and `HorizonDashboard.auth`. `dartisan pub:add horizon` writes `.withHorizon(createApp: createApp)` and explains both ways in.

### Fixed

- `daravel_horizon`: with `HORIZON_PATH=/` the dashboard's links and API calls started with `//`, which a browser reads as another host; they are now `/failed`, `/api/stats` and so on.

### Upgrade notes

- `daravel_horizon`: the dashboard is closed outside `APP_ENV=local` until the `viewHorizon` gate or `HorizonDashboard.auth` allows a request; middleware such as `['auth']` alone no longer opens it, and tests that relied on `APP_ENV=testing` need `HorizonDashboard.auth((request) => true)` (reset with `HorizonDashboard.auth(null)`) or the gate. New public name `HorizonDashboard.auth`.
