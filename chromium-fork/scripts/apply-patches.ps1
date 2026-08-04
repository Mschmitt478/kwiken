param(
  [string]$ChromiumRoot
)

. (Join-Path $PSScriptRoot "common.ps1")

$ChromiumRoot = Resolve-KwikenBuildRoot -Value $ChromiumRoot `
  -DefaultValue (Get-DefaultChromiumRoot) -Name "ChromiumRoot"
$sourceRoot = Assert-ChromiumCheckout -ChromiumRoot $ChromiumRoot
$patchRoot = Join-Path $script:ForkRoot "patches"
$patchPaths = @(Get-ChildItem -LiteralPath $patchRoot -Filter "*.patch" -File |
    Sort-Object -Property Name)
if ($patchPaths.Count -eq 0) {
  throw "No Kwiken source patches were found in $patchRoot."
}

Push-Location $sourceRoot
try {
  foreach ($patch in $patchPaths) {
    & git apply --reverse --check --ignore-space-change $patch.FullName 2>$null
    if ($LASTEXITCODE -eq 0) {
      Write-Output "Kwiken source patch is already applied: $($patch.Name)"
      continue
    }

    & git apply --check --ignore-space-change $patch.FullName
    if ($LASTEXITCODE -ne 0) {
      throw "Kwiken source patch $($patch.Name) does not apply cleanly. Reset the pinned checkout and try again."
    }
    & git apply --ignore-space-change $patch.FullName
    if ($LASTEXITCODE -ne 0) {
      throw "Could not apply Kwiken source patch $($patch.Name)."
    }
    Write-Output "Applied Kwiken source patch: $($patch.Name)"
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
$sourceDeltaHash = Assert-KwikenSourceDelta -SourceRoot $sourceRoot
Write-Output "Kwiken patches are applied to $sourceRoot (source delta $sourceDeltaHash)."
