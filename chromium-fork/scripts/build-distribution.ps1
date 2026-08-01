param(
  [string]$RuntimeArchive = "",
  [string]$RcEditPath = "",
  [string]$MakeNsisPath = "",
  [string]$PythonPath = ""
)

. (Join-Path $PSScriptRoot "common.ps1")

function Reset-BuildDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$AllowedRoot
  )

  $fullPath = [IO.Path]::GetFullPath($Path)
  $fullAllowedRoot = [IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\') + '\'
  if (-not $fullPath.StartsWith($fullAllowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to reset a directory outside $fullAllowedRoot`: $fullPath"
  }
  if (Test-Path -LiteralPath $fullPath) {
    Remove-Item -LiteralPath $fullPath -Recurse -Force
  }
  New-Item -ItemType Directory -Path $fullPath | Out-Null
  return $fullPath
}

function Import-VisualStudioEnvironment {
  $vsWhereCandidates = @(
    (Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"),
    (Join-Path $env:ProgramFiles "Microsoft Visual Studio\Installer\vswhere.exe")
  )
  $vsWhere = $vsWhereCandidates |
    Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1
  if (-not $vsWhere) {
    throw "Visual Studio Installer's vswhere.exe was not found."
  }

  $installationPath = & $vsWhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
  if ($LASTEXITCODE -ne 0 -or -not $installationPath) {
    throw "A Visual Studio installation with the C++ build tools was not found."
  }

  $vsDevCmd = Join-Path ($installationPath | Select-Object -First 1) "Common7\Tools\VsDevCmd.bat"
  if (-not (Test-Path -LiteralPath $vsDevCmd)) {
    throw "Visual Studio developer environment was not found at $vsDevCmd."
  }

  $environmentScript = Join-Path $cacheRoot "load-vs-environment.cmd"
  @(
    "@echo off",
    "call `"$vsDevCmd`" -no_logo -arch=x64 -host_arch=x64 >nul",
    "set"
  ) | Set-Content -LiteralPath $environmentScript -Encoding Ascii

  & cmd.exe /d /c $environmentScript | ForEach-Object {
    $separator = $_.IndexOf('=')
    if ($separator -gt 0) {
      [Environment]::SetEnvironmentVariable(
        $_.Substring(0, $separator),
        $_.Substring($separator + 1),
        [EnvironmentVariableTarget]::Process
      )
    }
  }
  if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    throw "Visual Studio C++ compiler was not available after loading VsDevCmd.bat."
  }
}

function Invoke-RcEdit {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Target,
    [Parameter(Mandatory = $true)]
    [string]$Description,
    [switch]$SetIcon
  )

  $arguments = @(
    $Target,
    "--set-version-string", "CompanyName", "Kwiken",
    "--set-version-string", "FileDescription", $Description,
    "--set-version-string", "ProductName", "Kwiken",
    "--set-version-string", "LegalCopyright", "Kwiken contributors and The Chromium Authors",
    "--set-file-version", $script:Version,
    "--set-product-version", $script:Version
  )
  if ($SetIcon) {
    $arguments += @("--set-icon", $iconPath)
  }
  & $RcEditPath @arguments
  if ($LASTEXITCODE -ne 0) {
    throw "rcedit failed for $Target with exit code $LASTEXITCODE."
  }
}

$cacheRoot = Join-Path $script:ForkRoot ".cache"
New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null

if (-not $RuntimeArchive) {
  $RuntimeArchive = Join-Path $cacheRoot "ungoogled-chromium_150.0.7871.186-1.1_windows_x64.zip"
}
if (-not (Test-Path -LiteralPath $RuntimeArchive)) {
  $runtimeUrl = "https://github.com/ungoogled-software/ungoogled-chromium-windows/releases/download/150.0.7871.186-1.1/ungoogled-chromium_150.0.7871.186-1.1_windows_x64.zip"
  $runtimeParent = Split-Path -Parent ([IO.Path]::GetFullPath($RuntimeArchive))
  New-Item -ItemType Directory -Force -Path $runtimeParent | Out-Null
  $partialArchive = "$RuntimeArchive.$PID.download"
  & curl.exe -L --fail --retry 3 --output $partialArchive $runtimeUrl
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to download the Chromium runtime archive."
  }
  Move-Item -LiteralPath $partialArchive -Destination $RuntimeArchive -Force
}

$expectedHash = "7dfb2233de9947f65cfe339ecc61e227fcccebb2e869e9361303ab08483bdc9c"
$actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $RuntimeArchive).Hash.ToLowerInvariant()
if ($actualHash -ne $expectedHash) {
  throw "Runtime archive checksum mismatch. Expected $expectedHash but found $actualHash."
}

if (-not $RcEditPath) {
  $rcEditCandidates = @(
    (Join-Path $script:ForkRoot ".tools\rcedit.exe"),
    (Join-Path $script:RepoRoot "browser-app\node_modules\electron-winstaller\vendor\rcedit.exe")
  )
  $rcEditCommand = Get-Command rcedit.exe -ErrorAction SilentlyContinue
  if ($rcEditCommand) {
    $rcEditCandidates += $rcEditCommand.Source
  }
  $RcEditPath = $rcEditCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $RcEditPath -or -not (Test-Path -LiteralPath $RcEditPath)) {
  throw "rcedit was not found. Pass -RcEditPath or place it at chromium-fork\.tools\rcedit.exe."
}

if (-not $MakeNsisPath) {
  $makeNsisCandidates = @(
    (Join-Path ${env:ProgramFiles(x86)} "NSIS\makensis.exe"),
    (Join-Path $env:ProgramFiles "NSIS\makensis.exe")
  )
  $cachedMakeNsis = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA "electron-builder\Cache") -Recurse -Filter "makensis.exe" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "nsis-3\.0\.4\.1" -and $_.DirectoryName -notmatch "\\Bin$" } |
    Select-Object -First 1 -ExpandProperty FullName
  if ($cachedMakeNsis) {
    $makeNsisCandidates += $cachedMakeNsis
  }
  $MakeNsisPath = $makeNsisCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $MakeNsisPath -or -not (Test-Path -LiteralPath $MakeNsisPath)) {
  throw "makensis.exe was not found. Build the Electron installer once or pass -MakeNsisPath."
}

$stagingRoot = Reset-BuildDirectory -Path (Join-Path $cacheRoot "distribution-staging") -AllowedRoot $cacheRoot
$archiveRoot = Reset-BuildDirectory -Path (Join-Path $cacheRoot "distribution-archive") -AllowedRoot $cacheRoot
$launcherBuildRoot = Reset-BuildDirectory -Path (Join-Path $cacheRoot "launcher-build") -AllowedRoot $cacheRoot
$runtimeRoot = Join-Path $stagingRoot "runtime"
New-Item -ItemType Directory -Path $runtimeRoot | Out-Null

& tar.exe -xf $RuntimeArchive -C $archiveRoot
if ($LASTEXITCODE -ne 0) {
  throw "Failed to extract the Chromium runtime archive."
}
$runtimeSource = Get-ChildItem -LiteralPath $archiveRoot -Directory | Select-Object -First 1
if (-not $runtimeSource -or -not (Test-Path -LiteralPath (Join-Path $runtimeSource.FullName "chrome.exe"))) {
  throw "The Chromium runtime archive has an unexpected layout."
}
Get-ChildItem -LiteralPath $runtimeSource.FullName -Force | Copy-Item -Destination $runtimeRoot -Recurse -Force

$iconPath = Join-Path $script:ForkRoot "assets\kwiken.ico"
if (-not (Test-Path -LiteralPath $iconPath)) {
  throw "Kwiken icon was not found at $iconPath."
}

Import-VisualStudioEnvironment
Copy-Item -LiteralPath $iconPath -Destination (Join-Path $launcherBuildRoot "kwiken.ico") -Force
Copy-Item -LiteralPath (Join-Path $script:ForkRoot "distribution\launcher\KwikenLauncher.manifest") -Destination $launcherBuildRoot -Force

Push-Location $launcherBuildRoot
try {
  & rc.exe /nologo /fo "KwikenLauncher.res" (Join-Path $script:ForkRoot "distribution\launcher\KwikenLauncher.rc")
  if ($LASTEXITCODE -ne 0) {
    throw "rc.exe failed with exit code $LASTEXITCODE."
  }
  & cl.exe /nologo /std:c++20 /O2 /MT /EHsc /DUNICODE /D_UNICODE /W4 `
    "/Fe:$(Join-Path $stagingRoot 'Kwiken.exe')" `
    (Join-Path $script:ForkRoot "distribution\launcher\KwikenLauncher.cpp") `
    "KwikenLauncher.res" shell32.lib ole32.lib user32.lib `
    /link /SUBSYSTEM:WINDOWS /MANIFEST:NO
  if ($LASTEXITCODE -ne 0) {
    throw "cl.exe failed with exit code $LASTEXITCODE."
  }
} finally {
  Pop-Location
}

if (-not $PythonPath) {
  $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
  if ($pythonCommand) {
    $PythonPath = $pythonCommand.Source
  }
}
if (-not $PythonPath -or -not (Test-Path -LiteralPath $PythonPath)) {
  throw "Python 3 was not found. Pass its executable path with -PythonPath."
}
& $PythonPath (Join-Path $script:ForkRoot "distribution\rebrand_paks.py") $runtimeRoot
if ($LASTEXITCODE -ne 0) {
  throw "Resource-pack branding failed with exit code $LASTEXITCODE."
}

Invoke-RcEdit -Target (Join-Path $runtimeRoot "chrome.exe") -Description "Kwiken Browser Engine" -SetIcon
Invoke-RcEdit -Target (Join-Path $runtimeRoot "chrome.dll") -Description "Kwiken Browser Engine"
Invoke-RcEdit -Target (Join-Path $runtimeRoot "notification_helper.exe") -Description "Kwiken Notifications" -SetIcon
Invoke-RcEdit -Target (Join-Path $runtimeRoot "chrome_proxy.exe") -Description "Kwiken Launcher Proxy" -SetIcon
Invoke-RcEdit -Target (Join-Path $runtimeRoot "chrome_pwa_launcher.exe") -Description "Kwiken Web App Launcher" -SetIcon

Copy-Item -LiteralPath (Join-Path $script:ForkRoot "distribution\licenses\chromium.txt") -Destination (Join-Path $stagingRoot "LICENSE.chromium.txt") -Force
Copy-Item -LiteralPath (Join-Path $script:ForkRoot "distribution\licenses\ungoogled-chromium-windows.txt") -Destination (Join-Path $stagingRoot "LICENSE.ungoogled-chromium-windows.txt") -Force
Copy-Item -LiteralPath (Join-Path $script:ForkRoot "distribution\licenses\rcedit.txt") -Destination (Join-Path $stagingRoot "LICENSE.rcedit.txt") -Force
Copy-Item -LiteralPath (Join-Path $script:ForkRoot "distribution\NOTICE.txt") -Destination $stagingRoot -Force

$releaseRoot = Join-Path $script:ForkRoot "release"
New-Item -ItemType Directory -Force -Path $releaseRoot | Out-Null
$installerPath = Join-Path $releaseRoot "Kwiken-Setup-$script:Version.exe"
& $MakeNsisPath `
  "/DVERSION=$script:Version" `
  "/DSTAGING=$stagingRoot" `
  "/DOUTFILE=$installerPath" `
  "/DICON=$iconPath" `
  (Join-Path $script:ForkRoot "distribution\installer\Kwiken.nsi")
if ($LASTEXITCODE -ne 0) {
  throw "makensis.exe failed with exit code $LASTEXITCODE."
}

Write-Output "Built Kwiken distribution: $installerPath"
