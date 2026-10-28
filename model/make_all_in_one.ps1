# Собирает model/all_in_one.sql из четырёх шагов: 01 -> 02 -> 03 -> 04.
#
#   powershell -File model/make_all_in_one.ps1
#
# Нужен, чтобы модель поднималась ОДНИМ файлом в любом клиенте:
# psql -f model/all_in_one.sql, или вставить в pgAdmin / DBeaver.
# Источник правды — файлы 01_…04_, при изменениях правим их и перегенерируем этот.

$ErrorActionPreference = "Stop"
$dir = $PSScriptRoot
$out = Join-Path $dir "all_in_one.sql"

$head = @"
-- =====================================================================
--  Модель данных Capibara целиком, одним файлом.
--
--  Файл собран скриптом model/make_all_in_one.ps1 (.sh) из четырёх шагов:
--    01_core.sql     -> схема core (факты и измерения) из raw
--    02_mart.sql     -> представления mart
--    03_answers.sql  -> ответы на 10 вопросов (блоки А и Б)
--    04_checks.sql   -> 15 проверок целостности и проба вброса
--
--  Запуск:  psql -f model/all_in_one.sql
--  Перед каждым шагом свои таблицы удаляются, поэтому запуск можно
--  повторять, результат каждый раз один и тот же.
-- =====================================================================
"@

$parts = @($head)
foreach ($f in @("01_core.sql", "02_mart.sql", "03_answers.sql", "04_checks.sql")) {
    $parts += ""
    $parts += "-- >>>>>>>>>>>>>>>>>>>>>>>>>>>> $f"
    $parts += (Get-Content -Raw -Encoding UTF8 (Join-Path $dir $f)).TrimEnd()
}

# piшем без BOM: с BOM файлы psql иногда не принимает
$utf8_no_bom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($out, ($parts -join "`n") + "`n", $utf8_no_bom)
Write-Host "готово: $out"
