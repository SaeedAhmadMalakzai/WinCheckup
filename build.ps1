<#
.SYNOPSIS
    Builds the release files into dist\: a portable zip, a Windows setup.exe and SHA256SUMS.txt.

.DESCRIPTION
    Runs on Windows PowerShell 5.1 or PowerShell 7 (Windows, macOS, Linux). The setup.exe needs NSIS 3
    (makensis on the PATH, or installed in Program Files). Without NSIS only the zip is built.

.PARAMETER Tag
    Release tag (for example v3.0.0). The build stops when it does not match the version in the script.

.PARAMETER SkipInstaller
    Build the portable zip only.

.EXAMPLE
    ./build.ps1
#>
[CmdletBinding()]
param(
    [string]$Tag,
    [switch]$SkipInstaller
)

$ErrorActionPreference = 'Stop'
$AppName = 'WinCheckup'
$Root = $PSScriptRoot
$Source = Join-Path $Root 'src'
$Assets = Join-Path $Root 'assets'
$BuildDir = Join-Path $Root 'build'
$Stage = Join-Path (Join-Path $BuildDir 'stage') $AppName
$Dist = Join-Path $Root 'dist'
$TextFiles = @('WinCheckup.ps1', 'WinCheckup.cmd', 'config.json', 'README.txt')

function Get-ToolVersion {
    $text = [System.IO.File]::ReadAllText((Join-Path $Source 'WinCheckup.ps1'))
    $match = [regex]::Match($text, "\`$script:ToolVersion = '(\d+\.\d+\.\d+)'")
    if (-not $match.Success) { throw 'The version line ($script:ToolVersion = ''x.y.z'') was not found in the script.' }
    return $match.Groups[1].Value
}

function Copy-WithCrlf {
    # Windows tools (cmd.exe, Notepad on older builds) expect CRLF; the ps1 must stay plain ASCII.
    param([string]$From, [string]$To)
    $text = [System.IO.File]::ReadAllText($From)
    $text = ($text -replace "`r`n", "`n") -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($To, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Find-MakeNsis {
    $command = Get-Command 'makensis' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if (-not $base) { continue }
        $candidate = Join-Path $base 'NSIS\makensis.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

$version = Get-ToolVersion
if ($Tag -and $Tag.TrimStart('v') -ne $version) { throw "Tag $Tag does not match the script version $version." }
Write-Host "Building $AppName $version"

foreach ($dir in @($BuildDir, $Dist)) {
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
}
New-Item -ItemType Directory -Path $Stage, $Dist -Force | Out-Null

foreach ($name in $TextFiles) { Copy-WithCrlf (Join-Path $Source $name) (Join-Path $Stage $name) }
Copy-WithCrlf (Join-Path $Root 'LICENSE') (Join-Path $Stage 'LICENSE.txt')
Copy-Item -LiteralPath (Join-Path $Assets "$AppName.ico") -Destination $Stage

$scriptBytes = [System.IO.File]::ReadAllBytes((Join-Path $Stage 'WinCheckup.ps1'))
if (@($scriptBytes | Where-Object { $_ -gt 127 }).Count -gt 0) { throw 'WinCheckup.ps1 contains non-ASCII characters.' }

$zip = Join-Path $Dist "$AppName-$version-portable.zip"
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($Stage, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $true)
Write-Host "  $zip"

if (-not $SkipInstaller) {
    $makensis = Find-MakeNsis
    if (-not $makensis) {
        Write-Warning 'NSIS (makensis) was not found - setup.exe skipped. Install NSIS 3 or use -SkipInstaller.'
    } else {
        $nsi = Join-Path (Join-Path $Root 'installer') "$AppName.nsi"
        & $makensis -V2 -NOCD "-DVERSION=$version" "-DSTAGE=$Stage" "-DOUTDIR=$Dist" $nsi
        if ($LASTEXITCODE -ne 0) { throw "makensis failed with exit code $LASTEXITCODE." }
        Write-Host ('  ' + (Join-Path $Dist "$AppName-$version-setup.exe"))
    }
}

$sums = foreach ($file in Get-ChildItem -LiteralPath $Dist -File | Sort-Object Name) {
    '{0}  {1}' -f (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $file.Name
}
[System.IO.File]::WriteAllText((Join-Path $Dist 'SHA256SUMS.txt'), (($sums -join "`n") + "`n"))
Write-Host "  $(Join-Path $Dist 'SHA256SUMS.txt')"
Write-Host 'Done.'
