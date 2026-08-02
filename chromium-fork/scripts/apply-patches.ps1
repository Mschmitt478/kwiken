param(
  [string]$ChromiumRoot = "C:\src\kwiken-chromium"
)

. (Join-Path $PSScriptRoot "common.ps1")

$sourceRoot = Assert-ChromiumCheckout -ChromiumRoot $ChromiumRoot
$patchPath = Join-Path $script:ForkRoot "patches\0001-kwiken-browser.patch"

Push-Location $sourceRoot
try {
  & git apply --reverse --check --ignore-space-change $patchPath 2>$null
  if ($LASTEXITCODE -ne 0) {
    & git apply --check --ignore-space-change $patchPath
    if ($LASTEXITCODE -ne 0) {
      throw "The Kwiken source patch does not apply cleanly. Reset the pinned checkout and try again."
    }
    & git apply --ignore-space-change $patchPath
    if ($LASTEXITCODE -ne 0) {
      throw "Could not apply the Kwiken source patch."
    }
  }

  $protectedAuthors = "__KWIKEN_UPSTREAM_AUTHORS__"
  foreach ($relativePath in @(
      "chrome\app\chromium_strings.grd",
      "chrome\app\settings_chromium_strings.grdp"
    )) {
    $path = Join-Path $sourceRoot $relativePath
    $content = [System.IO.File]::ReadAllText($path)
    $content = $content.Replace("The Chromium Authors", $protectedAuthors)
    $content = $content.Replace("Chromium", "Kwiken")
    $content = $content.Replace($protectedAuthors, "The Chromium Authors")
    [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
  }
} finally {
  Pop-Location
}

& (Join-Path $PSScriptRoot "generate-brand-assets.ps1") -SourceRoot $sourceRoot
Write-Output "Kwiken patches are applied to $sourceRoot."
