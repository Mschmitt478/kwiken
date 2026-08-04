param(
  [string]$ChromiumRoot,
  [string]$DepotToolsRoot,
  [string]$VisualStudioRoot,
  [ValidateSet("Bootstrap", "Build")]
  [string]$Stage = "Bootstrap"
)

. (Join-Path $PSScriptRoot "common.ps1")

$ChromiumRoot = Resolve-KwikenBuildRoot -Value $ChromiumRoot `
  -DefaultValue (Get-DefaultChromiumRoot) -Name "ChromiumRoot"
$DepotToolsRoot = Resolve-KwikenBuildRoot -Value $DepotToolsRoot `
  -DefaultValue (Get-DefaultDepotToolsRoot) -Name "DepotToolsRoot"

$isResumingCheckout =
  (Test-Path -LiteralPath (Join-Path $ChromiumRoot ".gclient")) -or
  (Test-Path -LiteralPath (Join-Path $ChromiumRoot "src\.git"))
$minimumFreeSpaceGB = if ($Stage -eq "Bootstrap" -and -not $isResumingCheckout) {
  100
} else {
  20
}
$parameters = @{
  ChromiumRoot = $ChromiumRoot
  DepotToolsRoot = $DepotToolsRoot
  VisualStudioRoot = $VisualStudioRoot
  MinimumFreeSpaceGB = $minimumFreeSpaceGB
  RequireDepotTools = $Stage -eq "Build"
}
Assert-ChromiumBuildPrerequisites @parameters | Out-Null
if ($Stage -eq "Build") {
  $sourceRoot = Assert-ChromiumCheckout -ChromiumRoot $ChromiumRoot
  Write-Output "Pinned Chromium checkout: $sourceRoot"
}
Write-Output "$Stage preflight passed."
