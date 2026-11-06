param(
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'common.ps1')

try {
    Write-Host "Removing $AppName" -ForegroundColor White
    $antigravity = Find-Antigravity

    if ($antigravity) {
        Write-Step 'Removing the extension from Antigravity'
        & $antigravity.Cli --uninstall-extension $ExtensionId | ForEach-Object { Write-Note $_ }

        Write-Step 'Closing the local debug port'
        Invoke-ArgvTool $antigravity @('disable', $antigravity.ArgvFile) | Out-Null
        Write-Done $antigravity.ArgvFile
    }

    Write-Step 'Removing the desktop switch and the uninstaller'
    Remove-Item $ShortcutPath -Force -ErrorAction SilentlyContinue
    Remove-Item $UninstallKey -Recurse -Force -ErrorAction SilentlyContinue
    Set-Location $env:TEMP
    Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Done 'Done.'

    Write-Host ''
    Write-Host "$AppName was removed. Restart Antigravity to finish." -ForegroundColor Green
    $failed = $false
} catch {
    Write-Host ''
    Write-Host "Uninstall failed: $($_.Exception.Message)" -ForegroundColor Red
    $failed = $true
}

if (-not $Yes) { Read-Host 'Press Enter to close' | Out-Null }
if ($failed) { exit 1 }
