# Get-AdminPortal.ps1
# Bootstrap script for the MFA Onboard Tool Admin Portal (Step 09)
#
# One-liner to invoke:
#   irm https://raw.githubusercontent.com/andrew-kemp/MFA-Onboard-Tool/main/Get-AdminPortal.ps1 | iex
#
# Or with an explicit path if your existing install is not in the default location:
#   & ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/andrew-kemp/MFA-Onboard-Tool/main/Get-AdminPortal.ps1'))) -ExistingInstallPath "C:\Scripts\MFA-Onboard-Tool-main\v2"

param(
    [string]$ExistingInstallPath = ""
)

# ── PS7 check ─────────────────────────────────────────────────────
if (-not ($PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.PSVersion.Major -ge 7)) {
    Write-Host "`n========================================" -ForegroundColor Red
    Write-Host "ERROR: PowerShell 7+ Required" -ForegroundColor Red
    Write-Host "========================================`n" -ForegroundColor Red
    Write-Host "Run this script in pwsh.exe (PowerShell 7), not Windows PowerShell." -ForegroundColor Yellow
    Write-Host "Install: winget install --id Microsoft.Powershell --source winget`n" -ForegroundColor Cyan
    exit 1
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " MFA Onboard Tool - Admin Portal Setup  " -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# ── 1. Find the existing install ──────────────────────────────────
function Find-ExistingInstall {
    # Common locations to probe — $PWD first so running from the install folder works
    # even when invoked via irm | iex (where $PSScriptRoot is empty)
    $candidates = @(
        $ExistingInstallPath,
        "$PWD\v2",
        $PWD,
        "$PSScriptRoot\v2",
        "$PSScriptRoot",
        "C:\Scripts\MFA-Onboard-Tool-main\v2",
        "C:\Scripts\MFA-Onboard-Tool\v2",
        "$HOME\Documents\MFA-Onboard-Tool-main\v2",
        "$HOME\Documents\MFA-Onboard-Tool\v2"
    ) | Where-Object { $_ }  # remove blanks

    foreach ($path in $candidates) {
        if (Test-Path (Join-Path $path "mfa-config.ini")) {
            return $path
        }
    }
    return $null
}

$v2Path = Find-ExistingInstall

if (-not $v2Path) {
    Write-Host "Could not automatically locate your existing MFA Onboard Tool install." -ForegroundColor Yellow
    Write-Host "Please enter the full path to your v2 folder (the one containing mfa-config.ini):" -ForegroundColor Yellow
    $v2Path = Read-Host "Path"
    $v2Path = $v2Path.Trim('"').Trim("'")
}

if (-not (Test-Path (Join-Path $v2Path "mfa-config.ini"))) {
    Write-Host "`n[ERROR] mfa-config.ini not found at: $v2Path" -ForegroundColor Red
    Write-Host "Ensure you point to the v2\ folder from your original MFA Onboard Tool deployment." -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Found existing install at: $v2Path" -ForegroundColor Green

# ── 2. Download latest repo zip ───────────────────────────────────
$repoZipUrl = "https://github.com/andrew-kemp/MFA-Onboard-Tool/archive/refs/heads/main.zip"
$zipFile    = "$env:TEMP\MFA-Onboard-Tool-update.zip"
$extractDir = "$env:TEMP\MFA-Onboard-Tool-update"

Write-Host "`nDownloading latest files from GitHub..." -ForegroundColor Yellow

try {
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    Invoke-WebRequest -Uri $repoZipUrl -OutFile $zipFile -UseBasicParsing
    Expand-Archive -Path $zipFile -DestinationPath $extractDir -Force
    Remove-Item $zipFile -Force
}
catch {
    Write-Host "[ERROR] Failed to download from GitHub: $_" -ForegroundColor Red
    exit 1
}

# GitHub zips extract into a subfolder named <repo>-<branch>
$repoRoot = Get-ChildItem -Path $extractDir -Directory | Select-Object -First 1
if (-not $repoRoot) {
    Write-Host "[ERROR] Could not find extracted repo folder in $extractDir" -ForegroundColor Red
    exit 1
}

$sourceV2           = Join-Path $repoRoot.FullName "v2"
$sourceFunctionCode = Join-Path $repoRoot.FullName "function-code"

Write-Host "[OK] Downloaded and extracted" -ForegroundColor Green

# ── 3. Copy new/updated files into the existing install ───────────
Write-Host "`nPatching existing install..." -ForegroundColor Yellow

# New function folders to copy in
$newFunctions = @("get-settings", "save-settings")
$destFunctionCode = Join-Path $v2Path "..\function-code" | Resolve-Path -ErrorAction SilentlyContinue
if (-not $destFunctionCode) {
    # function-code is a sibling of v2\
    $destFunctionCode = Join-Path (Split-Path $v2Path -Parent) "function-code"
}

foreach ($fn in $newFunctions) {
    $src  = Join-Path $sourceFunctionCode $fn
    $dest = Join-Path $destFunctionCode $fn

    if (-not (Test-Path $src)) {
        Write-Host "  [!] Source not found for function '$fn' — skipping" -ForegroundColor DarkYellow
        continue
    }

    if (Test-Path $dest) {
        Write-Host "  Updating: function-code\$fn" -ForegroundColor Gray
    }
    else {
        Write-Host "  Adding:   function-code\$fn" -ForegroundColor Gray
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
    }

    Copy-Item -Path "$src\*" -Destination $dest -Recurse -Force
}

# Copy 09-Setup-Admin-Portal.ps1
$src09  = Join-Path $sourceV2 "09-Setup-Admin-Portal.ps1"
$dest09 = Join-Path $v2Path "09-Setup-Admin-Portal.ps1"

if (Test-Path $src09) {
    Copy-Item -Path $src09 -Destination $dest09 -Force
    Write-Host "  Updated:  v2\09-Setup-Admin-Portal.ps1" -ForegroundColor Gray
}
else {
    Write-Host "  [!] 09-Setup-Admin-Portal.ps1 not found in repo download" -ForegroundColor DarkYellow
}

Write-Host "[OK] Files patched" -ForegroundColor Green

# ── 4. Clean up temp files ────────────────────────────────────────
Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue

# ── 5. Run Step 09 ────────────────────────────────────────────────
Write-Host "`nReady to run 09-Setup-Admin-Portal.ps1" -ForegroundColor Cyan
Write-Host "This will:" -ForegroundColor White
Write-Host "  - Create the MFASettings Storage Table" -ForegroundColor Gray
Write-Host "  - Seed it from your existing mfa-config.ini" -ForegroundColor Gray
Write-Host "  - Assign Managed Identity permissions" -ForegroundColor Gray
Write-Host "  - Deploy the updated function code" -ForegroundColor Gray
Write-Host ""

$confirm = Read-Host "Proceed? (Y/N)"
if ($confirm -notin @('Y', 'y')) {
    Write-Host "`nCancelled. Files have been patched — run 09-Setup-Admin-Portal.ps1 manually when ready." -ForegroundColor Yellow
    Write-Host "Location: $dest09`n" -ForegroundColor Cyan
    exit 0
}

Write-Host ""
& $dest09
