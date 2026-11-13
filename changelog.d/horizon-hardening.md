### Changed

- `daravel_horizon` dashboard (HZ-1): every request is authorized after its middleware, as Laravel Horizon's `Authenticate` middleware does. `APP_ENV=local` is open; otherwise `HorizonDashboard.auth(callback)` decides (Laravel's `Horizon::auth`), or without it the `viewHorizon` gate; anything else is a 403, for the page and every API route, mutations included. Middleware is no longer taken as protection, and `APP_ENV=testing` is no longer open. A callback or gate that throws denies the request and is logged. Without `middleware:`, `withHorizon()` uses the application's `web` group when it registers one (`withSession()`), else none; a `middleware:` entry the application does not register stops the boot with a `ConfigException` naming `withSession()` and `HorizonDashboard.auth`. `dartisan pub:add horizon` writes `.withHorizon(createApp: createApp)` and explains both ways in.

### Fixed

- `daravel_horizon` and `daravel_redis` Horizon stores: an error in `monitor`, `unmonitor`, `snapshot` or `horizon:prune` (a missing table, an unreachable Redis) is raised in the caller's zone. It used to escape into the root zone, where the work runs outside the caller's transaction, which ended the process and left the request waiting. The dashboard answers a store that cannot monitor or unmonitor a tag with a 500, logged, instead of a 204.
- `daravel_horizon`: with `HORIZON_PATH=/` the dashboard's links and API calls started with `//`, which a browser reads as another host; they are now `/failed`, `/api/stats` and so on.

- `daravel_horizon` dashboard: `/api/workload` counts the workers of each queue from the master's status (it read a list where the master writes the comma-separated queues of each worker, so `processes` was 0 and `wait` null), and `/api/jobs/pending` pages with `starting_at` and `limit` over the jobs of all the plan queues together (`starting_at` was ignored and `limit` applied to each queue).

- `daravel_redis` Horizon store: a page of more than 1 024 jobs (`recent`, `tagged`) failed with `RedisConnectionException` (too many commands waiting on the connection); the job records are now read 256 at a time.

### Upgrade notes

- `daravel_horizon`: the dashboard is closed outside `APP_ENV=local` until the `viewHorizon` gate or `HorizonDashboard.auth` allows a request; middleware such as `['auth']` alone no longer opens it, and tests that relied on `APP_ENV=testing` need `HorizonDashboard.auth((request) => true)` (reset with `HorizonDashboard.auth(null)`) or the gate. New public name `HorizonDashboard.auth`.
