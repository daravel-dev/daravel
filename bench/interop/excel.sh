#!/usr/bin/env bash
# Laravel 12 with maatwebsite/excel 3.1 (PhpSpreadsheet) and Daravel with
# daravel_excel (Linux and Docker): each reads the XLSX and CSV files the
# other writes, cell types included.
#
#   bash bench/interop/excel.sh
set -uo pipefail

WORK=${WORK:-$HOME/daravel-bench}
REPO=$(cd "$(dirname "$0")/../.." && pwd)

docker run --rm -v "$WORK:/w" dart:stable rm -rf /w/src /w/excel >/dev/null
mkdir -p "$WORK/src" "$WORK/pub-cache" "$WORK/excel"
tar -C "$REPO" --exclude=.git --exclude=.dart_tool --exclude=build \
  --exclude='docs/reviews' --exclude='docs/external-reviews' -cf - . |
  tar -C "$WORK/src" -xf -

docker build --network=host -q -t daravel-bench-laravel "$REPO/bench/laravel" >/dev/null
docker build --network=host -q -t daravel-interop-laravel-excel - >/dev/null <<'DOCKER'
FROM daravel-bench-laravel
RUN install-php-extensions gd \
 && composer require maatwebsite/excel:^3.1 --no-interaction -q
DOCKER

laravel() { # php code
  docker run --rm -v "$WORK/excel:/shared" --entrypoint php \
    daravel-interop-laravel-excel artisan tinker --execute="$1" 2>&1 | grep -v '^$' | tail -1
}
daravel() { # step
  docker run --rm -v "$WORK/excel:/shared" -v "$WORK/src:/src" \
    -v "$WORK/pub-cache:/root/.pub-cache" -w /src/bench dart:stable \
    sh -c "dart pub get >/dev/null 2>&1; dart run bin/excel_interop.dart $1 /shared" 2>&1 | tail -1
}

status=0
check() { # name expected actual
  if [[ "$3" == *"$2"* ]]; then echo "PASS $1"; else echo "FAIL $1: expected [$2] in [$3]"; status=1; fi
}

echo "== Daravel writes; Laravel Excel reads"
check "Daravel wrote" "written" "$(daravel write)"
read=$(laravel '$rows = Maatwebsite\Excel\Facades\Excel::toArray(new class implements Maatwebsite\Excel\Concerns\WithHeadingRow {}, "/shared/from-daravel.xlsx")[0];
  echo json_encode(["count" => count($rows), "first" => $rows[0], "second" => $rows[1], "last" => $rows[count($rows) - 1],
    "sheet" => Maatwebsite\Excel\Facades\Excel::toCollection(new class {}, "/shared/from-daravel.xlsx")->count(),
    "date" => PhpOffice\PhpSpreadsheet\Shared\Date::excelToDateTimeObject($rows[1]["tanggal"])->format("Y-m-d H:i")]);')
check "row count (3 002 rows after the headings)" '"count":3002' "$read"
check "text with escapes, integers, decimals, booleans, empty cells" '"first":{"nama":"Ana & \"Bo\" <x>","jumlah":42,"nilai":3.25,"aktif":true,"catatan":null' "$read"
check "Unicode, a negative, leading and trailing spaces kept" '"second":{"nama":"ünïcødé 🌴","jumlah":-7,"nilai":0.001,"aktif":false,"catatan":"  spasi  "' "$read"
check "a date written as an Excel date" '"date":"2026-10-28 07:30"' "$read"
check "the last row" '"last":{"nama":"Baris 3000","jumlah":3000,"nilai":750' "$read"
csv=$(laravel '$rows = Maatwebsite\Excel\Facades\Excel::toArray(new class implements Maatwebsite\Excel\Concerns\WithHeadingRow {}, "/shared/from-daravel.csv")[0]; echo json_encode([count($rows), $rows[0]]);')
check "Laravel Excel reads Daravel's CSV" '[3002,{"nama":"Ana & \"Bo\" <x>","jumlah":42,"nilai":3.25,"aktif":"TRUE","catatan":null,"tanggal":"2026-10-28"}]' "$csv"

echo "== Laravel Excel writes; Daravel reads"
laravel '$export = new class implements Maatwebsite\Excel\Concerns\FromArray, Maatwebsite\Excel\Concerns\WithHeadings {
    public function headings(): array { return ["Nama", "Jumlah", "Nilai", "Aktif", "Tanggal"]; }
    public function array(): array {
      $rows = [["Ana & Bo", 42, 3.25, true, PhpOffice\PhpSpreadsheet\Shared\Date::PHPToExcel(new DateTime("2026-10-28 07:30:00", new DateTimeZone("UTC")))], ["ünïcødé 🌴", -7, 0.001, false, null]];
      for ($i = 1; $i <= 2000; $i++) { $rows[] = ["Baris $i", $i, $i / 4, $i % 2 == 0, null]; }
      return $rows;
    }
  };
  file_put_contents("/shared/from-laravel.xlsx", Maatwebsite\Excel\Facades\Excel::raw($export, Maatwebsite\Excel\Excel::XLSX));
  file_put_contents("/shared/from-laravel.csv", Maatwebsite\Excel\Facades\Excel::raw($export, Maatwebsite\Excel\Excel::CSV));
  echo "ok";' >/dev/null
read=$(daravel read)
check "row count" '"count":2002' "$read"
check "shared strings, numbers, booleans from PhpSpreadsheet" '"first":{"nama":"Ana & Bo","jumlah":42,"nilai":3.25,"aktif":true' "$read"
check "the last row" '"last":{"nama":"Baris 2000","jumlah":2000,"nilai":500' "$read"
check "a date cell as its serial" '"date":"2026-10-28T07:30:00.000Z"' "$read"
check "Laravel Excel's CSV" '"csv_first":{"nama":"Ana & Bo","jumlah":42,"nilai":3.25' "$read"

[ $status -eq 0 ] && echo "All excel interop checks passed." || echo "Some excel interop checks failed."
exit $status
