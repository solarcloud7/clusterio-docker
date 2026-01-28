$ErrorActionPreference = "Stop"

$WorkspaceRoot = Resolve-Path "$PSScriptRoot/.."
$ConfigControlPath = Join-Path $WorkspaceRoot "data/controller/config-control.json"

if (Test-Path $ConfigControlPath) {
    $ConfigControl = Get-Content $ConfigControlPath -Raw | ConvertFrom-Json
    $Token = $ConfigControl.'control.controller_token'
    
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
} else {
    Write-Host "config-control.json not found at $ConfigControlPath" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "The controller may not have started yet. Try:" -ForegroundColor Yellow
    Write-Host "  docker exec clusterio-controller npx clusteriocontroller --log-level error bootstrap generate-user-token admin" -ForegroundColor Cyan
}
