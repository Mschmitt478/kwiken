$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:ForkRoot = Split-Path -Parent $PSScriptRoot
$script:RepoRoot = Split-Path -Parent $script:ForkRoot
$script:Version = (Get-Content (Join-Path $script:ForkRoot "VERSION") -Raw).Trim()
$script:Revision = (Get-Content (Join-Path $script:ForkRoot "REVISION") -Raw).Trim()

function Get-DefaultChromiumRoot {
  return "C:\src\kwiken-chromium"
}

function Get-DefaultDepotToolsRoot {
  return "C:\src\depot_tools"
}

function Set-ChromiumBuildEnvironment {
  param(
    [Parameter(Mandatory = $true)]
    [string]$DepotToolsRoot
  )

  $visualStudioRoot = "C:\Program Files\Microsoft Visual Studio\18\Community"
  if (-not (Test-Path $visualStudioRoot)) {
    throw "Visual Studio 2026 Community was not found at $visualStudioRoot."
  }

  $env:DEPOT_TOOLS_UPDATE = "0"
  $env:DEPOT_TOOLS_WIN_TOOLCHAIN = "0"
  $env:vs2026_install = $visualStudioRoot
  $env:PATH = "$DepotToolsRoot;$env:PATH"
}

function Assert-ChromiumCheckout {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ChromiumRoot
  )

  $sourceRoot = Join-Path $ChromiumRoot "src"
  if (-not (Test-Path (Join-Path $sourceRoot "chrome\VERSION"))) {
    throw "Chromium source was not found at $sourceRoot. Run bootstrap.ps1 first."
  }

  $actualRevision = (& git -C $sourceRoot rev-parse HEAD).Trim()
  if ($actualRevision -ne $script:Revision) {
    throw "Expected Chromium revision $script:Revision but found $actualRevision."
  }

  return $sourceRoot
}

function Invoke-BatchFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
  )

  & cmd.exe /d /c "call `"$Path`" $($Arguments -join ' ')"
  if ($LASTEXITCODE -ne 0) {
    throw "$Path failed with exit code $LASTEXITCODE."
  }
}
