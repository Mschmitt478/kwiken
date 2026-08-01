param(
  [string]$ChromiumRoot = "C:\src\kwiken-chromium",
  [string]$DepotToolsRoot = "C:\src\depot_tools"
)

. (Join-Path $PSScriptRoot "common.ps1")

if (-not (Test-Path (Join-Path $DepotToolsRoot ".git"))) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DepotToolsRoot) | Out-Null
  & git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git $DepotToolsRoot
  if ($LASTEXITCODE -ne 0) {
    throw "Could not clone depot_tools."
  }
}

Set-ChromiumBuildEnvironment -DepotToolsRoot $DepotToolsRoot

if (-not (Test-Path (Join-Path $ChromiumRoot "src\.git"))) {
  New-Item -ItemType Directory -Force -Path $ChromiumRoot | Out-Null
  Push-Location $ChromiumRoot
  try {
    Invoke-BatchFile -Path (Join-Path $DepotToolsRoot "fetch.bat") -Arguments @(
      "--nohooks",
      "--nohistory",
      "chromium"
    )
  } finally {
    Pop-Location
  }
}

$sourceRoot = Join-Path $ChromiumRoot "src"
Push-Location $sourceRoot
try {
  & git fetch --depth=1 origin "tag" $script:Version
  if ($LASTEXITCODE -ne 0) {
    throw "Could not fetch Chromium $script:Version."
  }
  & git checkout --detach $script:Version
  if ($LASTEXITCODE -ne 0) {
    throw "Could not check out Chromium $script:Version."
  }
  Invoke-BatchFile -Path (Join-Path $DepotToolsRoot "gclient.bat") -Arguments @(
    "sync",
    "-D",
    "--nohooks",
    "--no-history"
  )
  Invoke-BatchFile -Path (Join-Path $DepotToolsRoot "gclient.bat") -Arguments @("runhooks")
} finally {
  Pop-Location
}

Write-Output "Chromium $script:Version is ready at $sourceRoot."
