#!/usr/bin/env bash
# Собирает model/all_in_one.sql из семи шагов: 01 -> 02 -> 03 -> 04 -> 05 -> 06 -> 07.
#
#   bash model/make_all_in_one.sh
#
# Нужен, чтобы модель можно было поднять ОДНИМ файлом в любом клиенте:
# psql -f model/all_in_one.sql, или вставить его в pgAdmin / DBeaver.
# Источник правды — файлы 01_…07_, их и правим при изменениях, а этот
# файл перегенерируем.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$DIR/all_in_one.sql"

{
  # Шапка лежит в 00_header.sql — так обе сборки (sh и ps1) выдают один и тот
  # же файл, и кириллица нигде не зависит от кодировки исходника скрипта.
  cat "$DIR/00_header.sql"
  for f in 01_core.sql 02_mart.sql 03_answers.sql 04_checks.sql \
           05_history.sql 06_block_b.sql 07_checks_b.sql; do
    echo
    echo "-- >>>>>>>>>>>>>>>>>>>>>>>>>>>> $f"
    cat "$DIR/$f"
  done
} > "$OUT"

echo "готово: $OUT ($(wc -l < "$OUT") строк)"
