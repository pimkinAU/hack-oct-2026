#!/usr/bin/env bash
# Собирает модель целиком из raw: core -> mart -> ответы -> проверки.
#
#   bash model/build.sh
#
# Модели всё равно, была ли база чистой: 01_core.sql сначала удаляет
# свои таблицы и создаёт заново, поэтому запуск можно повторять.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for f in model/01_core.sql model/02_mart.sql model/03_answers.sql model/04_checks.sql; do
  echo
  echo "==> $f"
  docker compose exec -T postgres psql -U hack -d marketplace -v ON_ERROR_STOP=1 -P pager=off < "$f"
done
