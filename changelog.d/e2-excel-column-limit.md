### Fixed

- Security: `daravel_excel` took a cell reference past `XFD`, the last of the 16 384 columns a worksheet holds, at its word and padded the row with an empty cell for every column before it: a 786-byte `.xlsx` with a cell at `ZZZZZ1` became a row of 12 356 630 cells (225 MiB), and one at `ZZZZZZ1` did not finish. `columnIndex` now refuses a column past `XFD` with a `FormatException`, and so does a row of cells without references that runs past it, so reading such a file fails at once in bounded memory. A cell is written at its column, as PhpSpreadsheet writes a cell by its coordinate: a reference given again, or going back, sets that cell again (the last one wins), where 300 000 cells at `A1` used to make a row of 300 000 cells and `B1` then `A1` put A1 in column C. A cell reference is letters then digits (`""`, `1A1` and `12A34B5` are a `FormatException`, where digits used to be dropped wherever they were), and `columnIndex('')` throws instead of answering -1. Since 1.0.0.

### Upgrade notes

- Upgrading can make reading an `.xlsx` that references a column past `XFD` fail with a `FormatException`, and so can a malformed cell reference; no file Excel writes holds either. A repeated cell reference now keeps the last value. New public name: `maxColumns` (16 384).
