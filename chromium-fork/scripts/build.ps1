param(
  [string]$ChromiumRoot = "C:\src\kwiken-chromium",
  [string]$DepotToolsRoot = "C:\src\depot_tools",
  [ValidateRange(1, 12)]
  [int]$Jobs = 2,
  [switch]$SkipPatch
)

. (Join-Path $PSScriptRoot "common.ps1")

$sourceRoot = Assert-ChromiumCheckout -ChromiumRoot $ChromiumRoot
Set-ChromiumBuildEnvironment -DepotToolsRoot $DepotToolsRoot

if (-not $SkipPatch) {
  & (Join-Path $PSScriptRoot "apply-patches.ps1") -ChromiumRoot $ChromiumRoot
}

$outputRoot = Join-Path $sourceRoot "out\Kwiken"
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
Copy-Item (Join-Path $script:ForkRoot "args.gn") (Join-Path $outputRoot "args.gn") -Force

Push-Location $sourceRoot
try {
  Invoke-BatchFile -Path (Join-Path $DepotToolsRoot "gn.bat") -Arguments @(
    "gen",
    "out\Kwiken"
  )
  Invoke-BatchFile -Path (Join-Path $DepotToolsRoot "autoninja.bat") -Arguments @(
    "-C",
    "out\Kwiken",
    "chrome",
    "mini_installer",
    "-j",
    $Jobs.ToString()
  )
} finally {
  Pop-Location
}

$releaseRoot = Join-Path $script:ForkRoot "release"
New-Item -ItemType Directory -Force -Path $releaseRoot | Out-Null
$installerName = "Kwiken-Setup-$script:Version.exe"
Copy-Item (Join-Path $outputRoot "mini_installer.exe") (Join-Path $releaseRoot $installerName) -Force

Write-Output "Built installer: $(Join-Path $releaseRoot $installerName)"
