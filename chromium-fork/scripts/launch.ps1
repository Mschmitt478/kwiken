param(
  [string]$ChromiumRoot,
  [switch]$TemporaryProfile,
  [string[]]$AdditionalArguments = @(),
  [ValidateRange(1, 300)]
  [int]$StartupTimeoutSeconds = 30,
  [switch]$Wait,
  [switch]$PassThru
)

. (Join-Path $PSScriptRoot "common.ps1")
. (Join-Path $PSScriptRoot "launch-support.ps1")

$ChromiumRoot = Resolve-KwikenBuildRoot -Value $ChromiumRoot `
  -DefaultValue (Get-DefaultChromiumRoot) -Name "ChromiumRoot"
$sourceRoot = Assert-ChromiumCheckout -ChromiumRoot $ChromiumRoot
$browserPath = Join-Path $sourceRoot "out\Kwiken\chrome.exe"
if (-not (Test-Path $browserPath)) {
  throw "Kwiken has not been built yet. Run build.ps1 first."
}

$arguments = @()
if ($TemporaryProfile) {
  $profileRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("Kwiken-Test-Profile-" + [Guid]::NewGuid().ToString("N"))
  $arguments += "--user-data-dir=$profileRoot"
  $arguments += "--no-first-run"
  Write-Information "Temporary profile: $profileRoot" -InformationAction Continue
}
$arguments += $AdditionalArguments

$process = Start-KwikenBrowserProcess -FilePath $browserPath `
  -Arguments $arguments -WorkingDirectory (Split-Path -Parent $browserPath)
Wait-KwikenBrowserStartup -Process $process `
  -StartupTimeoutSeconds $StartupTimeoutSeconds
if ($Wait) {
  $process.WaitForExit()
  if ($process.ExitCode -ne 0) {
    throw "Kwiken exited with code $($process.ExitCode)."
  }
}
if ($PassThru) {
  return $process
}
