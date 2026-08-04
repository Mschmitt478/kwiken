param(
  [string]$ChromiumRoot,
  [string]$DepotToolsRoot,
  [string]$VisualStudioRoot,
  [ValidateRange(1, 12)]
  [int]$Jobs = 2,
  [switch]$SkipPatch
)

. (Join-Path $PSScriptRoot "common.ps1")

$ChromiumRoot = Resolve-KwikenBuildRoot -Value $ChromiumRoot `
  -DefaultValue (Get-DefaultChromiumRoot) -Name "ChromiumRoot"
$DepotToolsRoot = Resolve-KwikenBuildRoot -Value $DepotToolsRoot `
  -DefaultValue (Get-DefaultDepotToolsRoot) -Name "DepotToolsRoot"
$environmentSnapshot = New-ChromiumBuildEnvironmentSnapshot
try {

$preflightParameters = @{
  ChromiumRoot = $ChromiumRoot
  DepotToolsRoot = $DepotToolsRoot
  VisualStudioRoot = $VisualStudioRoot
  MinimumFreeSpaceGB = 20
  RequireDepotTools = $true
}
Assert-ChromiumBuildPrerequisites @preflightParameters | Out-Null
$sourceRoot = Assert-ChromiumCheckout -ChromiumRoot $ChromiumRoot
Set-ChromiumBuildEnvironment -DepotToolsRoot $DepotToolsRoot -VisualStudioRoot $VisualStudioRoot

if (-not $SkipPatch) {
  & (Join-Path $PSScriptRoot "apply-patches.ps1") -ChromiumRoot $ChromiumRoot
} else {
  Assert-KwikenSourceDelta -SourceRoot $sourceRoot | Out-Null
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

$releaseRoot = Join-Path $script:ForkRoot "release\native"
New-Item -ItemType Directory -Force -Path $releaseRoot | Out-Null
$installerName = "Kwiken-Native-MiniInstaller-$script:ReleaseVersion.exe"
Copy-Item (Join-Path $outputRoot "mini_installer.exe") (Join-Path $releaseRoot $installerName) -Force

Write-Output "Built native diagnostic installer: $(Join-Path $releaseRoot $installerName)"
} finally {
  Restore-ChromiumBuildEnvironment -Snapshot $environmentSnapshot
}
