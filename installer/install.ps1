param(
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

. (Join-Path $PSScriptRoot 'common.ps1')

$WingetId = 'Google.AntigravityIDE'
$ManifestRoot = 'manifests/g/Google/AntigravityIDE'

function Confirm-Choice([string]$Question) {
    if ($Yes) { return $true }
    $answer = Read-Host "  $Question [Y/n]"
    return (-not $answer) -or ($answer -match '^(y|yes)$')
}

function Get-Architecture {
    try {
        return [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLower()
    } catch {
        if ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64' -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { return 'arm64' }
        return 'x64'
    }
}

function Test-Requirements {
    if ([Environment]::OSVersion.Version.Major -lt 10) {
        throw 'Auto Click needs Windows 10 or Windows 11.'
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'Auto Click needs 64-bit Windows.'
    }
}

function Get-AntigravityDownload {
    $headers = @{ 'User-Agent' = 'antigravity-auto-click-installer' }
    $api = "https://api.github.com/repos/microsoft/winget-pkgs/contents/$ManifestRoot"

    $entries = Invoke-RestMethod $api -Headers $headers
    $latest = $entries |
        Where-Object { $_.type -eq 'dir' -and $_.name -as [version] } |
        Sort-Object { [version]$_.name } |
        Select-Object -Last 1
    if (-not $latest) { throw 'Could not find the latest Antigravity IDE version.' }

    $yaml = Invoke-RestMethod "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/$ManifestRoot/$($latest.name)/$WingetId.installer.yaml" -Headers $headers
    $architecture = Get-Architecture
    $pattern = '(?ms)^- Architecture:\s*(?<arch>\S+)\s*$.*?InstallerUrl:\s*(?<url>\S+).*?InstallerSha256:\s*(?<sha>\S+)'
    $match = [regex]::Matches($yaml, $pattern) | Where-Object { $_.Groups['arch'].Value -eq $architecture } | Select-Object -First 1
    if (-not $match) { throw "No Antigravity IDE installer is published for $architecture Windows." }

    $url = $match.Groups['url'].Value
    if ($url -notmatch '^https://([a-z0-9-]+\.)*(gvt1\.com|google\.com|googleapis\.com)/') {
        throw "Refusing to download Antigravity from an unexpected address: $url"
    }

    [pscustomobject]@{
        Version = $latest.name
        Url     = $url
        Sha256  = $match.Groups['sha'].Value.ToUpper()
    }
}

function Install-AntigravityFromGoogle {
    $download = Get-AntigravityDownload
    $file = Join-Path $env:TEMP "AntigravityIDE-$($download.Version)-setup.exe"

    Write-Note "Downloading Antigravity IDE $($download.Version) from Google..."
    Invoke-WebRequest $download.Url -OutFile $file -UseBasicParsing

    $hash = (Get-FileHash $file -Algorithm SHA256).Hash
    if ($hash -ne $download.Sha256) {
        Remove-Item $file -Force
        throw 'The downloaded installer does not match its published SHA256 fingerprint. It was deleted and not run.'
    }
    Write-Note 'Fingerprint verified. Installing...'

    $setup = Start-Process $file -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/mergetasks=!runcode' -Wait -PassThru
    Remove-Item $file -Force -ErrorAction SilentlyContinue
    if ($setup.ExitCode -ne 0) { throw "The Antigravity IDE installer failed (exit code $($setup.ExitCode))." }
}

function Install-Antigravity {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Note 'Installing Antigravity IDE with winget...'
        winget install --id $WingetId --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
        if ($LASTEXITCODE -eq 0) { return }
        Write-Note "winget could not install it (exit code $LASTEXITCODE). Trying Google's download instead."
    }
    Install-AntigravityFromGoogle
}

function Install-Extension($Antigravity) {
    $vsix = Get-ChildItem $PSScriptRoot -Filter '*.vsix' | Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $vsix) { throw 'The .vsix file is missing. Download the full release zip again.' }

    & $Antigravity.Cli --install-extension $vsix.FullName --force | ForEach-Object { Write-Note $_ }
    if ($LASTEXITCODE -ne 0) { throw "Antigravity could not install the extension (exit code $LASTEXITCODE)." }

    if ($vsix.BaseName -match '(\d+\.\d+\.\d+)$') { return $Matches[1] }
    return '1.0.0'
}

function Install-Files {
    New-Item -ItemType Directory -Force $InstallDir | Out-Null
    foreach ($name in 'common.ps1', 'uninstall.ps1', 'Uninstall.cmd', 'argv.js', 'auto-click.ico') {
        Copy-Item (Join-Path $PSScriptRoot $name) $InstallDir -Force
    }
}

function New-DesktopSwitch($Antigravity) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $Antigravity.Exe
    $shortcut.Arguments = "--open-url -- `"$($Antigravity.UrlProtocol)://$ExtensionId/toggle`""
    $shortcut.WorkingDirectory = $Antigravity.Folder
    $shortcut.IconLocation = "$InstallDir\auto-click.ico,0"
    $shortcut.Description = 'Turn Auto Click on or off'
    $shortcut.Save()
}

function Register-Uninstaller([string]$Version) {
    New-Item $UninstallKey -Force | Out-Null
    $strings = @{
        DisplayName     = $AppName
        DisplayVersion  = $Version
        Publisher       = $AppName
        DisplayIcon     = "$InstallDir\auto-click.ico"
        InstallLocation = $InstallDir
        UninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\uninstall.ps1`""
    }
    foreach ($name in $strings.Keys) {
        New-ItemProperty $UninstallKey -Name $name -Value $strings[$name] -PropertyType String -Force | Out-Null
    }
    foreach ($name in 'NoModify', 'NoRepair') {
        New-ItemProperty $UninstallKey -Name $name -Value 1 -PropertyType DWord -Force | Out-Null
    }
}

function Test-DebugPort([int]$Port) {
    try {
        Invoke-RestMethod "http://127.0.0.1:$Port/json/version" -TimeoutSec 3 | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Restart-Antigravity($Antigravity) {
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-AntigravityProcess $Antigravity) -and (Get-Date) -lt $deadline) {
        Get-AntigravityProcess $Antigravity |
            Where-Object { $_.MainWindowHandle -ne 0 } |
            ForEach-Object { $_.CloseMainWindow() | Out-Null }
        Start-Sleep -Seconds 2
    }
    if (Get-AntigravityProcess $Antigravity) {
        Write-Note 'Antigravity is still open (it may be asking you to save something).'
        Write-Note 'Close it yourself and open it again to finish setup.'
        return
    }
    Start-Process $Antigravity.Exe
    Write-Done 'Antigravity restarted.'
}

try {
    Write-Host "$AppName setup" -ForegroundColor White
    Test-Requirements

    Write-Step 'Looking for Antigravity IDE'
    $antigravity = Find-Antigravity
    if ($antigravity) {
        Write-Done "Found $($antigravity.Name) $($antigravity.Version)"
    } else {
        Write-Note 'Antigravity IDE is not installed on this computer.'
        Write-Note "Installing it means you accept Google's terms: https://antigravity.google/terms"
        if (-not (Confirm-Choice 'Download and install Antigravity IDE now (about 220 MB)?')) {
            throw 'Auto Click needs Antigravity IDE. Nothing was changed.'
        }
        Install-Antigravity
        $antigravity = Find-Antigravity
        if (-not $antigravity) { throw 'Antigravity IDE was installed but could not be found.' }
        Write-Done "Installed $($antigravity.Name) $($antigravity.Version)"
    }

    Write-Step 'Opening a local debug port for Antigravity'
    $port = [int](Invoke-ArgvTool $antigravity @('enable', $antigravity.ArgvFile, $DefaultDebugPort))
    Write-Done "Port $port on 127.0.0.1 ($($antigravity.ArgvFile))"

    Write-Step 'Installing the Auto Click extension'
    $version = Install-Extension $antigravity
    Write-Done "Extension $ExtensionId $version"

    Write-Step 'Adding the desktop switch and the uninstaller'
    Install-Files
    New-DesktopSwitch $antigravity
    Register-Uninstaller $version
    Write-Done "Desktop: $ShortcutPath"
    Write-Done "Uninstall from Windows Settings > Apps, or run $InstallDir\Uninstall.cmd"

    Write-Step 'Starting'
    if (Get-AntigravityProcess $antigravity) {
        if (Test-DebugPort $port) {
            Write-Done 'Antigravity is running and Auto Click is active.'
        } elseif (Confirm-Choice 'Antigravity has to restart once to finish setup. Restart it now?') {
            Restart-Antigravity $antigravity
        } else {
            Write-Note 'Close Antigravity and open it again to finish setup.'
        }
    } elseif (Confirm-Choice 'Open Antigravity now?') {
        Start-Process $antigravity.Exe
        Write-Done 'Antigravity is starting.'
    }

    Write-Host ''
    Write-Host 'All set. Look for "Auto Click" in the Antigravity status bar.' -ForegroundColor Green
    Write-Host 'The first time you use the desktop switch, Antigravity asks to allow the link:'
    Write-Host 'tick "Do not ask me again for this extension" and click Open.'
    Write-Host 'If this is a fresh Antigravity install, sign in with your Google account first.'
    $failed = $false
} catch {
    Write-Host ''
    Write-Host "Setup failed: $($_.Exception.Message)" -ForegroundColor Red
    $failed = $true
}

if (-not $Yes) { Read-Host 'Press Enter to close' | Out-Null }
if ($failed) { exit 1 }
