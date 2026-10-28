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

# Шапку берём из файла 00_header.sql и читаем его явно в UTF-8. Внутри .ps1
# текст держать нельзя: Windows PowerShell 5.1 читает исходники не в UTF-8, и
# кириллица в готовом all_in_one.sql превращается в кракозябры.
$head = (Get-Content -Raw -Encoding UTF8 (Join-Path $dir "00_header.sql")).TrimEnd()

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
