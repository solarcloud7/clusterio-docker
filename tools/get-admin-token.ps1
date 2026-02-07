$ErrorActionPreference = "Stop"

# Get admin username from env file or use default
$EnvFile = Join-Path $PSScriptRoot "..\env\controller.env"
$AdminUser = "admin"
if (Test-Path $EnvFile) {
    $EnvContent = Get-Content $EnvFile
    foreach ($line in $EnvContent) {
        if ($line -match "^INIT_CLUSTERIO_ADMIN=(.+)$") {
            $AdminUser = $Matches[1].Trim()
            break
        }
    }
}

Write-Host ""
Write-Host "Retrieving admin token for user: $AdminUser" -ForegroundColor Cyan

# Read token from config-control.json
$ConfigJson = docker exec clusterio-controller cat /clusterio/tokens/config-control.json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to read token. Is the controller running?" -ForegroundColor Red
    Write-Host $ConfigJson -ForegroundColor Yellow
    exit 1
}

# Parse the token from the JSON
try {
    $Config = $ConfigJson | ConvertFrom-Json
    $Token = $Config.'control.controller_token'
    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw "Token not found in config"
    }
} catch {
    Write-Host "Failed to parse token from config file" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "Admin Token:" -ForegroundColor Yellow
Write-Host $Token -ForegroundColor White
Write-Host ""

# Copy to clipboard if available
try {
    $Token | Set-Clipboard
    Write-Host "(Copied to clipboard)" -ForegroundColor Green
} catch {
    # Clipboard not available
}

