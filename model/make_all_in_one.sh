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
  echo "-- ====================================================================="
  echo "--  Модель данных Capibara целиком, одним файлом."
  echo "--"
  echo "--  Файл собран скриптом model/make_all_in_one.sh из семи шагов:"
  echo "--    01_core.sql     -> схема core (факты и измерения) из raw"
  echo "--    02_mart.sql     -> представления mart"
  echo "--    03_answers.sql  -> ответы на 5 вопросов блока А"
  echo "--    04_checks.sql   -> 10 проверок целостности"
  echo "--    05_history.sql  -> история адресов покупателей, продавцов и категорий"
  echo "--    06_block_b.sql  -> ответы на 5 вопросов блока Б"
  echo "--    07_checks_b.sql -> 12 проверок истории и блока Б"
  echo "--"
  echo "--  Запуск:  psql -f model/all_in_one.sql"
  echo "--           или docker compose exec -T postgres psql -U hack -d marketplace < model/all_in_one.sql"
  echo "--  Перед каждым шагом свои таблицы удаляются, поэтому запуск"
  echo "--  повторять можно, результат каждый раз один и тот же."
  echo "-- ====================================================================="
  for f in 01_core.sql 02_mart.sql 03_answers.sql 04_checks.sql \
           05_history.sql 06_block_b.sql 07_checks_b.sql; do
    echo
    echo "-- >>>>>>>>>>>>>>>>>>>>>>>>>>>> $f"
    cat "$DIR/$f"
  done
} > "$OUT"

echo "готово: $OUT ($(wc -l < "$OUT") строк)"
