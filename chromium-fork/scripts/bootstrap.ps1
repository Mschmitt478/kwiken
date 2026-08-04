param(
  [string]$ChromiumRoot,
  [string]$DepotToolsRoot,
  [string]$VisualStudioRoot,
  [ValidateRange(1, 32)]
  [int]$SyncJobs = 4,
  [ValidateRange(1, 10)]
  [int]$SyncAttempts = 4,
  [switch]$PreflightOnly
)

. (Join-Path $PSScriptRoot "common.ps1")

function Invoke-ResumableGClientSync {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $syncArguments = @($Arguments) + @("--jobs", $SyncJobs.ToString())
  for ($attempt = 1; $attempt -le $SyncAttempts; $attempt++) {
    try {
      Invoke-BatchFile -Path (Join-Path $DepotToolsRoot "gclient.bat") `
        -Arguments $syncArguments
      return
    } catch {
      if ($attempt -eq $SyncAttempts) {
        throw
      }

      # Chromium's anonymous Git hosts can briefly rate-limit a new checkout.
      # gclient sync is resumable, so retry with bounded parallelism rather than
      # discarding the many repositories that already completed successfully.
      $retryDelaySeconds = [Math]::Min(60, 15 * $attempt)
      Write-Warning "gclient sync attempt $attempt failed. Retrying the partial checkout in $retryDelaySeconds seconds."
      Start-Sleep -Seconds $retryDelaySeconds
    }
  }
}

function Set-PinnedGClientConfiguration {
  $gclientConfig = @"
solutions = [
  {
    "name": "src",
    "url": "https://chromium.googlesource.com/chromium/src.git@$script:Revision",
    "custom_deps": {},
    "custom_vars": {},
  },
]
"@
  [IO.File]::WriteAllText(
    (Join-Path $ChromiumRoot ".gclient"),
    $gclientConfig,
    [Text.UTF8Encoding]::new($false)
  )
}

$ChromiumRoot = Resolve-KwikenBuildRoot -Value $ChromiumRoot `
  -DefaultValue (Get-DefaultChromiumRoot) -Name "ChromiumRoot"
$DepotToolsRoot = Resolve-KwikenBuildRoot -Value $DepotToolsRoot `
  -DefaultValue (Get-DefaultDepotToolsRoot) -Name "DepotToolsRoot"
Assert-DistinctBuildRoots -ChromiumRoot $ChromiumRoot -DepotToolsRoot $DepotToolsRoot
$environmentSnapshot = New-ChromiumBuildEnvironmentSnapshot
try {
  Set-ChromiumGitEnvironment
  $env:DEPOT_TOOLS_UPDATE = "0"

  $isResumingCheckout =
    (Test-Path -LiteralPath (Join-Path $ChromiumRoot ".gclient")) -or
    (Test-Path -LiteralPath (Join-Path $ChromiumRoot "src\.git"))
  $preflightParameters = @{
    ChromiumRoot = $ChromiumRoot
    DepotToolsRoot = $DepotToolsRoot
    VisualStudioRoot = $VisualStudioRoot
    MinimumFreeSpaceGB = $(if ($isResumingCheckout) { 20 } else { 100 })
  }
  Assert-ChromiumBuildPrerequisites @preflightParameters | Out-Null
  if ($PreflightOnly) {
    Write-Output "Bootstrap preflight passed."
    return
  }

if (-not (Test-Path -LiteralPath (Join-Path $DepotToolsRoot ".git"))) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DepotToolsRoot) | Out-Null
  & git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git $DepotToolsRoot
  if ($LASTEXITCODE -ne 0) {
    throw "Could not clone depot_tools."
  }
}

$depotToolsChanges = & git -C $DepotToolsRoot status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0 -or $depotToolsChanges) {
  throw "The depot_tools checkout at $DepotToolsRoot has tracked changes. Preserve or revert them before bootstrapping Kwiken."
}
& git -C $DepotToolsRoot fetch --depth=1 origin $script:DepotToolsRevision
if ($LASTEXITCODE -ne 0) {
  throw "Could not fetch depot_tools revision $script:DepotToolsRevision."
}
& git -C $DepotToolsRoot checkout --detach $script:DepotToolsRevision
if ($LASTEXITCODE -ne 0) {
  throw "Could not check out depot_tools revision $script:DepotToolsRevision."
}

Initialize-DepotTools -DepotToolsRoot $DepotToolsRoot
Set-ChromiumBuildEnvironment -DepotToolsRoot $DepotToolsRoot -VisualStudioRoot $VisualStudioRoot
New-Item -ItemType Directory -Force -Path $ChromiumRoot | Out-Null
Set-PinnedGClientConfiguration

if (-not (Test-Path -LiteralPath (Join-Path $ChromiumRoot "src\.git"))) {
  Push-Location $ChromiumRoot
  try {
    Write-Output "Starting or resuming the pinned Chromium checkout at $ChromiumRoot."
    Invoke-ResumableGClientSync -Arguments @(
      "sync",
      "-D",
      "--nohooks",
      "--no-history"
    )
  } finally {
    Pop-Location
  }
}

$sourceRoot = Join-Path $ChromiumRoot "src"
Push-Location $sourceRoot
try {
  & git fetch --depth=1 origin $script:Revision
  if ($LASTEXITCODE -ne 0) {
    throw "Could not fetch Chromium revision $script:Revision."
  }
  & git checkout --detach $script:Revision
  if ($LASTEXITCODE -ne 0) {
    throw "Could not check out Chromium revision $script:Revision."
  }
  Invoke-ResumableGClientSync -Arguments @(
    "sync",
    "-D",
    "--nohooks",
    "--no-history"
  )
  Invoke-BatchFile -Path (Join-Path $DepotToolsRoot "gclient.bat") -Arguments @("runhooks")
} finally {
  Pop-Location
}

$actualVersion = Get-Content (Join-Path $sourceRoot "chrome\VERSION")
$versionParts = @{}
foreach ($line in $actualVersion) {
  if ($line -match '^(MAJOR|MINOR|BUILD|PATCH)=(\d+)$') {
    $versionParts[$Matches[1]] = $Matches[2]
  }
}
$checkoutVersion = "$($versionParts.MAJOR).$($versionParts.MINOR).$($versionParts.BUILD).$($versionParts.PATCH)"
if ($checkoutVersion -ne $script:Version) {
  throw "Chromium revision $script:Revision reports version $checkoutVersion, expected $script:Version."
}

Write-Output "Chromium $script:Version ($script:Revision) is ready at $sourceRoot."
} finally {
  Restore-ChromiumBuildEnvironment -Snapshot $environmentSnapshot
}
