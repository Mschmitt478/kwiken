param(
  [Parameter(Mandatory = $true)]
  [string]$SourceRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$forkRoot = Split-Path -Parent $PSScriptRoot
$assetRoot = Join-Path $forkRoot "assets"
$canonicalAssetRoot = Join-Path $assetRoot "chromium"
$themeRoot = Join-Path $SourceRoot "chrome\app\theme\chromium"
$windowsThemeRoot = Join-Path $themeRoot "win"
$tileRoot = Join-Path $windowsThemeRoot "tiles"

$assetCopies = @(
  @((Join-Path $canonicalAssetRoot "product_logo_16.png"), (Join-Path $themeRoot "product_logo_16.png")),
  @((Join-Path $canonicalAssetRoot "product_logo_24.png"), (Join-Path $themeRoot "product_logo_24.png")),
  @((Join-Path $canonicalAssetRoot "product_logo_48.png"), (Join-Path $themeRoot "product_logo_48.png")),
  @((Join-Path $canonicalAssetRoot "product_logo_64.png"), (Join-Path $themeRoot "product_logo_64.png")),
  @((Join-Path $canonicalAssetRoot "product_logo_128.png"), (Join-Path $themeRoot "product_logo_128.png")),
  @((Join-Path $assetRoot "kwiken-icon.png"), (Join-Path $themeRoot "product_logo_256.png")),
  @((Join-Path $assetRoot "kwiken.ico"), (Join-Path $windowsThemeRoot "chromium.ico")),
  @((Join-Path $assetRoot "kwiken.ico"), (Join-Path $windowsThemeRoot "app_list.ico")),
  @((Join-Path $canonicalAssetRoot "Logo.png"), (Join-Path $tileRoot "Logo.png")),
  @((Join-Path $canonicalAssetRoot "SmallLogo.png"), (Join-Path $tileRoot "SmallLogo.png"))
)

foreach ($copy in $assetCopies) {
  $source = [string]$copy[0]
  $destination = [string]$copy[1]
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw "Canonical Kwiken brand asset is missing: $source"
  }
  if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
    throw "Pinned Chromium asset target is missing: $destination"
  }
  Copy-Item -LiteralPath $source -Destination $destination -Force
}

Write-Output "Copied canonical Kwiken product assets into $themeRoot."
