# Собирает model/all_in_one.sql из семи шагов: 01 -> 02 -> 03 -> 04 -> 05 -> 06 -> 07.
#
#   powershell -File model/make_all_in_one.ps1
#
# Нужен, чтобы модель поднималась ОДНИМ файлом в любом клиенте:
# psql -f model/all_in_one.sql, или вставить в pgAdmin / DBeaver.
# Источник правды — файлы 01_…07_, при изменениях правим их и перегенерируем этот.

$ErrorActionPreference = "Stop"
$dir = $PSScriptRoot
$out = Join-Path $dir "all_in_one.sql"

$head = @"
-- =====================================================================
--  Модель данных Capibara целиком, одним файлом.
--
--  Файл собран скриптом model/make_all_in_one.ps1 (.sh) из семи шагов:
--    01_core.sql     -> схема core (факты и измерения) из raw
--    02_mart.sql     -> представления mart
--    03_answers.sql  -> ответы на 5 вопросов блока А
--    04_checks.sql   -> 10 проверок целостности
--    05_history.sql  -> история адресов покупателей, продавцов и категорий
--    06_block_b.sql  -> ответы на 5 вопросов блока Б
--    07_checks_b.sql -> 12 проверок истории и блока Б
--
--  Запуск:  psql -f model/all_in_one.sql
--  Перед каждым шагом свои таблицы удаляются, поэтому запуск можно
--  повторять, результат каждый раз один и тот же.
-- =====================================================================
"@

$parts = @($head)
foreach ($f in @("01_core.sql", "02_mart.sql", "03_answers.sql", "04_checks.sql",
                 "05_history.sql", "06_block_b.sql", "07_checks_b.sql")) {
    $parts += ""
    $parts += "-- >>>>>>>>>>>>>>>>>>>>>>>>>>>> $f"
    $parts += (Get-Content -Raw -Encoding UTF8 (Join-Path $dir $f)).TrimEnd()
}

# пишем без BOM: с BOM файлы psql иногда не принимает
$utf8_no_bom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($out, ($parts -join "`n") + "`n", $utf8_no_bom)
Write-Host "готово: $out"
