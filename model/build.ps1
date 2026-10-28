# Собирает модель целиком из raw: core -> mart -> ответы -> проверки.
#
#   pwsh -File model/build.ps1
#
# 01_core.sql сначала удаляет свои таблицы и создаёт их заново,
# поэтому запуск можно повторять сколько угодно раз.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

foreach ($f in @("model/01_core.sql", "model/02_mart.sql", "model/03_answers.sql", "model/04_checks.sql",
                 "model/05_history.sql", "model/06_block_b.sql", "model/07_checks_b.sql")) {
    Write-Host ""
    Write-Host "==> $f"
    Get-Content -Raw $f | docker compose exec -T postgres psql -U hack -d marketplace -v ON_ERROR_STOP=1 -P pager=off
    if ($LASTEXITCODE -ne 0) { throw "остановились на $f" }
}
