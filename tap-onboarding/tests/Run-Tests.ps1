param(
    [string]$Path = "$PSScriptRoot"
)

if (-not (Get-Module -ListAvailable -Name Pester)) {
    Write-Host 'Pester module not found. Install with: Install-Module Pester -Scope CurrentUser -Force' -ForegroundColor Yellow
    exit 1
}

Invoke-Pester -Path $Path -Output Detailed
