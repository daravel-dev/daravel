# Changelog

## 1.15.0

- First release: XLSX and CSV exports and imports with Laravel Excel 3.1's concerns. Exports from `FromQuery` (a chunk at a time), `FromCollection` or `FromGenerator`, with `WithHeadings`, `WithMapping`, `WithTitle`, `WithMultipleSheets`, `WithColumnFormatting`, `WithColumnWidths`, `WithCustomCsvSettings`, streamed by `Excel.download`, `Excel.store` (any disk), `Excel.raw` and `Excel.stream` at a constant 24 MB for 10 000 to 500 000 rows. Imports with `ToModel` (or `WithBatchInserts`), `ToCollection`, `OnEachRow`, `WithHeadingRow`, `WithValidation` (`ExcelValidationException`, failures with sheet row numbers, a 422), `SkipsOnFailure`/`SkipsFailures`, `SkipsEmptyRows`, `WithChunkReading`, `WithStartRow`, `WithLimit` and sheet selection, in one transaction; `Excel.toArray`. A streaming ZIP writer and reader with a ZIP-bomb limit, `ExcelDate`, `NumberFormat`, and `make:export` / `make:import` (`package:daravel_excel/commands.dart`).
