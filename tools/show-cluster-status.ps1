$ErrorActionPreference = "Stop"

$WorkspaceRoot = Resolve-Path "$PSScriptRoot/.."
Set-Location $WorkspaceRoot

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Clusterio Cluster Status" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Container status
Write-Host "Containers:" -ForegroundColor Yellow
docker compose ps
Write-Host ""

# Check controller health
$health = docker inspect --format='{{.State.Health.Status}}' clusterio-controller 2>$null
if ($health) {
    $color = switch ($health) {
        "healthy" { "Green" }
        "unhealthy" { "Red" }
        default { "Yellow" }
    }
    Write-Host "Controller Health: $health" -ForegroundColor $color
} else {
    Write-Host "Controller Health: not running" -ForegroundColor Red
}
Write-Host ""

# Show plugins
$PluginsDir = Join-Path $WorkspaceRoot "plugins"
$PluginCount = (Get-ChildItem -Path $PluginsDir -Directory -ErrorAction SilentlyContinue | Measure-Object).Count
Write-Host "Plugins ($PluginCount):" -ForegroundColor Yellow
if ($PluginCount -gt 0) {
    Get-ChildItem -Path $PluginsDir -Directory | ForEach-Object {
        $PluginJson = Join-Path $_.FullName "package.json"
        if (Test-Path $PluginJson) {
            $Pkg = Get-Content $PluginJson -Raw | ConvertFrom-Json
            Write-Host "  - $($_.Name) v$($Pkg.version)" -ForegroundColor Cyan
        } else {
            Write-Host "  - $($_.Name)" -ForegroundColor Cyan
        }
    }
} else {
    Write-Host "  (none)" -ForegroundColor Gray
}
Write-Host ""

# Web UI info
$envFile = Join-Path $WorkspaceRoot ".env"
if (Test-Path $envFile) {
    $port = (Get-Content $envFile | Where-Object { $_ -match "^CONTROLLER_HTTP_PORT=" }) -replace "CONTROLLER_HTTP_PORT=", ""
    if ($port) {
        Write-Host "Web UI: http://localhost:$port" -ForegroundColor Cyan
    }
}
