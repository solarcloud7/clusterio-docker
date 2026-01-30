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
Write-Host "Generating admin token for user: $AdminUser" -ForegroundColor Cyan

# Generate token via docker exec
$Token = docker exec clusterio-controller npx clusteriocontroller --log-level error bootstrap generate-user-token $AdminUser 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to generate token. Is the controller running?" -ForegroundColor Red
    Write-Host $Token -ForegroundColor Yellow
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

