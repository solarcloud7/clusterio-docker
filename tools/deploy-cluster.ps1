<#
.SYNOPSIS
    Hot-deploy Clusterio source changes to running containers.

.DESCRIPTION
    Builds the Clusterio TypeScript source locally and copies the compiled
    output into running Docker containers without rebuilding images.

    Much faster than `docker compose build` for iterative development (~6s
    per container vs minutes for a full image rebuild).

    Deploys compiled dist/ directories only. If you change dependencies
    (package.json), you still need `docker compose build` to update
    node_modules inside the image.

    Requires: pnpm, Docker

.PARAMETER Target
    Which containers to deploy to: all (default), controller, or hosts.

.PARAMETER NoBuild
    Skip the pnpm build step. Deploy previously compiled artifacts.

.PARAMETER BuildOnly
    Only build locally. Do not deploy to containers or restart.

.PARAMETER NoRestart
    Deploy files but skip container restart. Useful for inspecting changes
    before restarting.

.EXAMPLE
    .\tools\deploy-cluster.ps1
    # Build and deploy to all containers

.EXAMPLE
    .\tools\deploy-cluster.ps1 -Target controller
    # Build and deploy to controller only

.EXAMPLE
    .\tools\deploy-cluster.ps1 -NoBuild
    # Deploy previously compiled artifacts (skip pnpm install)

.EXAMPLE
    .\tools\deploy-cluster.ps1 -NoBuild -Target hosts -NoRestart
    # Deploy to hosts without building or restarting
#>
[CmdletBinding()]
param(
    [ValidateSet("all", "controller", "hosts")]
    [string]$Target = "all",
    [switch]$NoBuild,
    [switch]$BuildOnly,
    [switch]$NoRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$timer = [System.Diagnostics.Stopwatch]::StartNew()

# ─── Configuration ────────────────────────────────────────────────────
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$SourceDir   = Join-Path $ProjectRoot "clusterio"
$SuppressJS  = Join-Path $ProjectRoot "scripts" "suppress-dev-warning.js"
$ComposeFile = Join-Path $ProjectRoot "docker-compose.yml"

# Compiled output directories to deploy
$distPaths = @(
    "packages/controller/dist"
    "packages/ctl/dist"
    "packages/host/dist"
    "packages/lib/dist"
    "packages/web_ui/dist"
)

# ─── Helpers ──────────────────────────────────────────────────────────
function Write-Step([string]$Icon, [string]$Message) {
    Write-Host "  $Icon " -NoNewline -ForegroundColor Cyan
    Write-Host $Message
}

function Write-Ok([string]$Message) {
    Write-Host "  ✓ " -NoNewline -ForegroundColor Green
    Write-Host $Message
}

function Write-Fail([string]$Message) {
    Write-Host "  ✗ " -NoNewline -ForegroundColor Red
    Write-Host $Message
}

function Write-Detail([string]$Message) {
    Write-Host "    $Message" -ForegroundColor DarkGray
}

function Get-Elapsed {
    "{0:N1}s" -f $timer.Elapsed.TotalSeconds
}

# ─── Banner ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Clusterio Hot Deploy" -ForegroundColor Yellow
Write-Host "  ════════════════════" -ForegroundColor DarkGray
Write-Detail "Target: $Target"
Write-Host ""

# ─── Preflight Checks ────────────────────────────────────────────────

# 1. Verify CLUSTERIO_TARGET=custom in docker-compose.yml
if (Test-Path $ComposeFile) {
    $composeContent = Get-Content $ComposeFile -Raw
    if ($composeContent -notmatch 'CLUSTERIO_TARGET:\s*custom') {
        Write-Fail "CLUSTERIO_TARGET is not set to 'custom' in docker-compose.yml"
        Write-Detail "This script only works with a custom Clusterio build (local fork)."
        Write-Detail "Set CLUSTERIO_TARGET: custom in docker-compose.yml first."
        exit 1
    }
}

# 2. Source directory
if (-not (Test-Path (Join-Path $SourceDir "package.json"))) {
    Write-Fail "Clusterio source not found at: $SourceDir"
    Write-Detail "Clone your fork:  git clone <url> clusterio/"
    exit 1
}

# 2. pnpm (if building)
if (-not $NoBuild) {
    if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
        Write-Fail "pnpm not found. Install:  npm install -g pnpm"
        exit 1
    }
}

# 3. Discover running containers
if (-not $BuildOnly) {
    Push-Location $ProjectRoot
    try {
        [string[]]$runningNames = @(docker compose -f $ComposeFile ps --format '{{.Name}}' 2>$null |
            Where-Object { $_ -match 'clusterio' })
    }
    finally { Pop-Location }

    if ($runningNames.Count -eq 0) {
        Write-Fail "No running Clusterio containers found."
        Write-Detail "Start cluster:  docker compose up -d"
        exit 1
    }

    [string[]]$ctrlContainers = @($runningNames | Where-Object { $_ -match 'controller' })
    [string[]]$hostContainers = @($runningNames | Where-Object { $_ -match 'host' } | Sort-Object)

    [string[]]$containers = @(switch ($Target) {
        "controller" { $ctrlContainers }
        "hosts"      { $hostContainers }
        "all"        { $ctrlContainers + $hostContainers }
    })

    if ($containers.Count -eq 0) {
        Write-Fail "No matching containers for target '$Target'."
        exit 1
    }

    Write-Ok "Containers: $($containers -join ', ')"
}

# ─── Step 1: Build ───────────────────────────────────────────────────
if (-not $NoBuild) {
    Write-Step "🔨" "Building TypeScript..."
    $buildTimer = [System.Diagnostics.Stopwatch]::StartNew()

    Push-Location $SourceDir
    try {
        # pnpm install triggers prepare scripts (TypeScript compile + webpack bundle)
        $buildOutput = pnpm install 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "pnpm install failed:"
            $buildOutput | ForEach-Object { Write-Detail "$_" }
            exit 1
        }
        if ($VerbosePreference -eq "Continue") {
            $buildOutput | ForEach-Object { Write-Detail "$_" }
        }
    }
    finally { Pop-Location }

    Write-Ok "Build complete ($("{0:N1}s" -f $buildTimer.Elapsed.TotalSeconds))"
}
else {
    Write-Detail "Build skipped (-NoBuild)"
}

if ($BuildOnly) {
    Write-Host ""
    Write-Ok "Build only — done in $(Get-Elapsed)"
    Write-Host ""
    exit 0
}

# ─── Step 2: Deploy ──────────────────────────────────────────────────
Write-Host ""

# Include plugin dist dirs that exist locally
[string[]]$allDistPaths = $distPaths
Get-ChildItem (Join-Path $SourceDir "plugins") -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName "dist") } |
    ForEach-Object { $allDistPaths += "plugins/$($_.Name)/dist" }

foreach ($c in $containers) {
    $deployTimer = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Step "📦" "Deploying to $c..."

    # Copy each compiled dist/ directory into the container
    $copied = 0
    foreach ($dp in $allDistPaths) {
        $localDist = Join-Path $SourceDir ($dp -replace '/', '\')
        if (-not (Test-Path $localDist)) {
            Write-Verbose "Skipping $dp (not found locally)"
            continue
        }
        # docker cp copies contents of local dir into container dir
        docker cp "${localDist}/." "${c}:/clusterio/${dp}/" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Failed to copy $dp to $c"
            exit 1
        }
        $copied++
    }

    # Fix file ownership (container runs as clusterio user)
    foreach ($dp in $allDistPaths) {
        docker exec $c chown -R clusterio:clusterio "/clusterio/$dp" 2>$null
    }

    # Re-apply suppress-dev-warning patch (dist/ overwrite reverts build-time patch)
    docker cp $SuppressJS "${c}:/tmp/suppress-dev-warning.js" 2>$null
    docker exec -w /clusterio $c node /tmp/suppress-dev-warning.js 2>$null
    docker exec $c rm -f /tmp/suppress-dev-warning.js 2>$null

    Write-Ok "$c — $copied dist dirs deployed ($("{0:N1}s" -f $deployTimer.Elapsed.TotalSeconds))"
}

# ─── Step 3: Restart ─────────────────────────────────────────────────
Write-Host ""
if (-not $NoRestart) {
    Write-Step "🔄" "Restarting containers..."
    Push-Location $ProjectRoot
    try {
        docker compose -f $ComposeFile restart @containers 2>&1 |
            ForEach-Object { Write-Detail "$_" }
    }
    finally { Pop-Location }

    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Restart failed"
        exit 1
    }
    Write-Ok "Containers restarted"
}
else {
    Write-Detail "Restart skipped (-NoRestart)"
    Write-Detail "Restart manually:  docker compose restart $($containers -join ' ')"
}

# ─── Done ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Ok "Deploy complete in $(Get-Elapsed)"
Write-Host ""
