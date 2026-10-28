#!/usr/bin/env bash
# Собирает model/all_in_one.sql из четырёх шагов: 01 -> 02 -> 03 -> 04.
#
#   bash model/make_all_in_one.sh
#
# Нужен, чтобы модель можно было поднять ОДНИМ файлом в любом клиенте:
# psql -f model/all_in_one.sql, или вставить его в pgAdmin / DBeaver.
# Источник правды — файлы 01_…04_, их и правим при изменениях, а этот
# файл перегенерируем.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$DIR/all_in_one.sql"

{
  echo "-- ====================================================================="
  echo "--  Модель данных Capibara целиком, одним файлом."
  echo "--"
  echo "--  Файл собран скриптом model/make_all_in_one.sh из четырёх шагов:"
  echo "--    01_core.sql     -> схема core (факты и измерения) из raw"
  echo "--    02_mart.sql     -> представления mart"
  echo "--    03_answers.sql  -> ответы на 10 вопросов (блоки А и Б)"
  echo "--    04_checks.sql   -> 15 проверок целостности и проба вброса"
  echo "--"
  echo "--  Запуск:  psql -f model/all_in_one.sql"
  echo "--           или docker compose exec -T postgres psql -U hack -d marketplace < model/all_in_one.sql"
  echo "--  Перед каждым шагом свои таблицы удаляются, поэтому запуск"
  echo "--  повторять можно, результат каждый раз один и тот же."
  echo "-- ====================================================================="
  for f in 01_core.sql 02_mart.sql 03_answers.sql 04_checks.sql; do
    echo
    echo "-- >>>>>>>>>>>>>>>>>>>>>>>>>>>> $f"
    cat "$DIR/$f"
  done
} > "$OUT"

echo "готово: $OUT ($(wc -l < "$OUT") строк)"
