$AppName = 'Google Antigravity Auto Click on Accept Button'
$ExtensionId = 'antigravity-auto-click.accept-button'
$DefaultDebugPort = 9333
$InstallDir = Join-Path $env:LOCALAPPDATA 'Antigravity Auto Click'
$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AntigravityAutoClick'
$ShortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk"

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "> $Message" -ForegroundColor Cyan
}

function Write-Done([string]$Message) {
    Write-Host "  $Message" -ForegroundColor Green
}

function Write-Note([string]$Message) {
    Write-Host "  $Message"
}

function Find-Antigravity {
    $roots = @("$env:LOCALAPPDATA\Programs", $env:ProgramFiles, ${env:ProgramFiles(x86)}) |
        Where-Object { $_ -and (Test-Path $_) }

    foreach ($root in $roots) {
        foreach ($folder in Get-ChildItem $root -Directory -ErrorAction SilentlyContinue) {
            $productFile = Join-Path $folder.FullName 'resources\app\product.json'
            if (-not (Test-Path $productFile)) { continue }

            $product = Get-Content $productFile -Raw | ConvertFrom-Json
            if ($product.nameShort -notlike '*Antigravity*' -or -not $product.dataFolderName) { continue }

            $exe = Join-Path $folder.FullName "$($product.nameShort).exe"
            if (-not (Test-Path $exe)) {
                $exe = Get-ChildItem $folder.FullName -Filter '*.exe' |
                    Where-Object { $_.Name -notlike 'unins*' } |
                    Select-Object -First 1 -ExpandProperty FullName
            }
            if (-not $exe) { continue }

            return [pscustomobject]@{
                Name        = $product.nameShort
                Folder      = $folder.FullName
                Exe         = $exe
                Cli         = Join-Path $folder.FullName "bin\$($product.applicationName).cmd"
                ArgvFile    = Join-Path $env:USERPROFILE "$($product.dataFolderName)\argv.json"
                UrlProtocol = $product.urlProtocol
                Version     = (Get-Item $exe).VersionInfo.ProductVersion
            }
        }
    }
}

function Get-AntigravityProcess($Antigravity) {
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Antigravity.Exe }
}

function Invoke-ArgvTool($Antigravity, [string[]]$Arguments) {
    $script = Join-Path $PSScriptRoot 'argv.js'
    $info = New-Object System.Diagnostics.ProcessStartInfo $Antigravity.Exe
    $info.Arguments = (@($script) + $Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['ELECTRON_RUN_AS_NODE'] = '1'

    $process = [System.Diagnostics.Process]::Start($info)
    $output = $process.StandardOutput.ReadToEnd()
    $errors = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "Could not update $($Antigravity.ArgvFile): $($errors.Trim())"
    }
    $output.Trim()
}
