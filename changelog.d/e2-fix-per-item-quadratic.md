### Fixed

- `in_array` walked the whole input for each item: 8 000 numbers against 8 000 took 52 s. It now gathers the other values once per validation run and decides exactly as before. This came in after 1.27.1 and was never released. (The same fix for `distinct` was released in 1.27.2.)
