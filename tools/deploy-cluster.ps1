param (
    [switch]$ForceBaseBuild,
    [switch]$CleanData
)

$ErrorActionPreference = "Stop"

# Paths
$WorkspaceRoot = Resolve-Path "$PSScriptRoot/.."
$DataDir = Join-Path $WorkspaceRoot "data"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Clusterio Docker Cluster Deploy" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check for .env file
$EnvFile = Join-Path $WorkspaceRoot ".env"
if (-not (Test-Path $EnvFile)) {
    Write-Host "WARNING: .env file not found!" -ForegroundColor Yellow
    Write-Host "Copy .env.template to .env and configure your settings." -ForegroundColor Yellow
    Write-Host ""
    
    $EnvTemplate = Join-Path $WorkspaceRoot ".env.template"
    if (Test-Path $EnvTemplate) {
        $CreateEnv = Read-Host "Create .env from template now? (y/N)"
        if ($CreateEnv -eq 'y' -or $CreateEnv -eq 'Y') {
            Copy-Item $EnvTemplate $EnvFile
            Write-Host "Created .env from template. Please edit it with your settings." -ForegroundColor Green
            Write-Host "Then run this script again." -ForegroundColor Yellow
            exit 0
        }
    }
}

# Check for plugins
$PluginsDir = Join-Path $WorkspaceRoot "plugins"
if (-not (Test-Path $PluginsDir)) {
    New-Item -ItemType Directory -Path $PluginsDir -Force | Out-Null
    Write-Host "Created plugins/ directory" -ForegroundColor Green
}

$PluginCount = (Get-ChildItem -Path $PluginsDir -Directory -ErrorAction SilentlyContinue | Measure-Object).Count
if ($PluginCount -eq 0) {
    Write-Host "INFO: No custom plugins in plugins/ directory (official plugins are built-in)" -ForegroundColor Gray
} else {
    Write-Host "Found $PluginCount plugin(s):" -ForegroundColor Green
    Get-ChildItem -Path $PluginsDir -Directory | ForEach-Object {
        $PluginJson = Join-Path $_.FullName "package.json"
        if (Test-Path $PluginJson) {
            $Pkg = Get-Content $PluginJson -Raw | ConvertFrom-Json
            Write-Host "  - $($_.Name) v$($Pkg.version)" -ForegroundColor Cyan
        } else {
            Write-Host "  - $($_.Name) (no package.json)" -ForegroundColor Yellow
        }
    }
}
Write-Host ""

Set-Location $WorkspaceRoot

# 1. Clean data if requested
if ($CleanData) {
    Write-Host "Cleaning all cluster data..." -ForegroundColor Yellow
    docker compose down -v 2>$null
    
    if (Test-Path $DataDir) {
        Remove-Item -Recurse -Force $DataDir -ErrorAction SilentlyContinue
        Write-Host "Removed data/ directory" -ForegroundColor Green
    }
    Write-Host ""
}

# 2. Build Base Image (skip if exists unless -ForceBaseBuild)
$baseImageName = "solarcloud7/clusterio-docker:latest"
$imageExists = docker image inspect $baseImageName 2>$null
if ($ForceBaseBuild -or -not $imageExists) {
    Write-Host "Building Base Image..." -ForegroundColor Cyan
    docker build -t $baseImageName -f Dockerfile.base .
    if ($LASTEXITCODE -ne 0) { throw "Base image build failed" }
    Write-Host ""
} else {
    Write-Host "Base image already exists, skipping build (use -ForceBaseBuild to rebuild)" -ForegroundColor Yellow
    Write-Host ""
}

# 3. Stop existing containers
Write-Host "Stopping existing containers..." -ForegroundColor Cyan
docker compose down 2>$null
Write-Host ""

# 4. Bring up cluster
Write-Host "Starting cluster..." -ForegroundColor Cyan
docker compose up -d --build
if ($LASTEXITCODE -ne 0) { throw "Failed to start cluster" }
Write-Host ""

# 5. Wait for controller to be healthy
Write-Host "Waiting for controller to be healthy..." -ForegroundColor Cyan
$maxAttempts = 30
$attempt = 0
while ($attempt -lt $maxAttempts) {
    $health = docker inspect --format='{{.State.Health.Status}}' clusterio-controller 2>$null
    if ($health -eq "healthy") {
        Write-Host "Controller is healthy!" -ForegroundColor Green
        break
    }
    $attempt++
    Write-Host "  Attempt $attempt/$maxAttempts - Status: $health" -ForegroundColor Gray
    Start-Sleep -Seconds 2
}
if ($attempt -ge $maxAttempts) {
    Write-Host "WARNING: Controller did not become healthy in time" -ForegroundColor Yellow
}
Write-Host ""

# 6. Follow init logs
Write-Host "Clusterio Init Logs:" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor DarkGray

$initExists = docker ps -a --filter "name=clusterio-init" --format "{{.Names}}" 2>$null
if ($initExists) {
    docker logs -f clusterio-init 2>&1
} else {
    Write-Host "clusterio-init container not found (may have already completed)" -ForegroundColor Yellow
}

Write-Host "================================================" -ForegroundColor DarkGray
Write-Host ""
