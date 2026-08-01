param(
  [string]$ChromiumRoot = "C:\src\kwiken-chromium",
  [switch]$TemporaryProfile
)

. (Join-Path $PSScriptRoot "common.ps1")

$sourceRoot = Assert-ChromiumCheckout -ChromiumRoot $ChromiumRoot
$browserPath = Join-Path $sourceRoot "out\Kwiken\chrome.exe"
if (-not (Test-Path $browserPath)) {
  throw "Kwiken has not been built yet. Run build.ps1 first."
}

$arguments = @()
if ($TemporaryProfile) {
  $profileRoot = Join-Path $env:TEMP "Kwiken-Test-Profile"
  $arguments += "--user-data-dir=$profileRoot"
  $arguments += "--no-first-run"
}

Start-Process -FilePath $browserPath -ArgumentList $arguments
