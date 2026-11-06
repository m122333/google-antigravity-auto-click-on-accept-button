$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$root = $PSScriptRoot
$package = Get-Content (Join-Path $root 'extension\package.json') -Raw | ConvertFrom-Json
$version = $package.version
$dist = Join-Path $root 'dist'
$releaseName = "Antigravity-Auto-Click-$version"
$utf8 = New-Object System.Text.UTF8Encoding $false

function Escape-Xml([string]$Text) {
    [System.Security.SecurityElement]::Escape($Text)
}

function Write-Zip([string]$Path, [System.Collections.Specialized.OrderedDictionary]$Entries) {
    $zip = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
    try {
        foreach ($name in $Entries.Keys) {
            $content = $Entries[$name]
            $bytes = if ($content -is [string]) { $utf8.GetBytes($content) } else { [System.IO.File]::ReadAllBytes($content.FullName) }
            $entry = $zip.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Optimal)
            $stream = $entry.Open()
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        }
    } finally {
        $zip.Dispose()
    }
}

$manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Language="en-US" Id="$($package.name)" Version="$version" Publisher="$($package.publisher)" />
    <DisplayName>$(Escape-Xml $package.displayName)</DisplayName>
    <Description xml:space="preserve">$(Escape-Xml $package.description)</Description>
    <Tags>$(Escape-Xml ($package.keywords -join ','))</Tags>
    <Categories>$(Escape-Xml ($package.categories -join ','))</Categories>
    <GalleryFlags>Public</GalleryFlags>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="$($package.engines.vscode)" />
      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="$($package.extensionKind -join ',')" />
    </Properties>
    <License>extension/LICENSE.txt</License>
    <Icon>extension/icon.png</Icon>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code" />
  </Installation>
  <Dependencies />
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true" />
    <Asset Type="Microsoft.VisualStudio.Services.Content.Details" Path="extension/README.md" Addressable="true" />
    <Asset Type="Microsoft.VisualStudio.Services.Content.License" Path="extension/LICENSE.txt" Addressable="true" />
    <Asset Type="Microsoft.VisualStudio.Services.Icons.Default" Path="extension/icon.png" Addressable="true" />
  </Assets>
</PackageManifest>
"@

$contentTypes = @"
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension=".json" ContentType="application/json" />
  <Default Extension=".js" ContentType="application/javascript" />
  <Default Extension=".md" ContentType="text/markdown" />
  <Default Extension=".txt" ContentType="text/plain" />
  <Default Extension=".png" ContentType="image/png" />
  <Default Extension=".vsixmanifest" ContentType="text/xml" />
</Types>
"@

if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
$release = New-Item -ItemType Directory (Join-Path $dist $releaseName)

$vsixEntries = [ordered]@{
    '[Content_Types].xml'    = $contentTypes
    'extension.vsixmanifest' = $manifest
}
foreach ($file in Get-ChildItem (Join-Path $root 'extension') -File) {
    $vsixEntries["extension/$($file.Name)"] = $file
}
$vsixEntries['extension/icon.png'] = Get-Item (Join-Path $root 'assets\icon.png')
$vsixEntries['extension/README.md'] = Get-Item (Join-Path $root 'README.md')
$vsixEntries['extension/LICENSE.txt'] = Get-Item (Join-Path $root 'LICENSE')
$vsix = Join-Path $release "antigravity-auto-click-$version.vsix"
Write-Zip $vsix $vsixEntries

$releaseFiles = @(
    Get-ChildItem (Join-Path $root 'installer') -File
    Get-Item (Join-Path $root 'extension\argv.js')
    Get-Item (Join-Path $root 'assets\auto-click.ico')
    Get-Item (Join-Path $root 'README.md')
    Get-Item (Join-Path $root 'LICENSE')
)
foreach ($file in $releaseFiles) {
    Copy-Item $file.FullName $release.FullName
}

$zipEntries = [ordered]@{}
foreach ($file in Get-ChildItem $release.FullName -File) {
    $zipEntries["$releaseName/$($file.Name)"] = $file
}
$zip = Join-Path $dist "$releaseName.zip"
Write-Zip $zip $zipEntries

Write-Host "Built $vsix"
Write-Host "Built $zip"
