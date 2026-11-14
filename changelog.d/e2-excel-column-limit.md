### Fixed

- Security: `daravel_excel` took a cell reference past `XFD`, the last of the 16 384 columns a worksheet holds, at its word and padded the row with an empty cell for every column before it: a 786-byte `.xlsx` with a cell at `ZZZZZ1` became a row of 12 356 630 cells (225 MiB), and one at `ZZZZZZ1` did not finish. `columnIndex` now refuses a column past `XFD` with a `FormatException`, and so does a row of cells without references that runs past it, so reading such a file fails at once in bounded memory. Since 1.0.0.

### Upgrade notes

- Upgrading can make reading an `.xlsx` that references a column past `XFD` fail with a `FormatException`; no file Excel writes holds one. New public name: `maxColumns` (16 384).
