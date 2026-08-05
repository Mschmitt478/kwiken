$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path (Split-Path -Parent $PSScriptRoot) "scripts\common.ps1")
. (Join-Path (Split-Path -Parent $PSScriptRoot) "scripts\launch-support.ps1")

$failures = [Collections.Generic.List[string]]::new()

function Invoke-Test {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [scriptblock]$Body
  )

  try {
    & $Body
    Write-Output "PASS $Name"
  } catch {
    $script:failures.Add("$Name`: $($_.Exception.Message)")
    Write-Output "FAIL $Name"
  }
}

function Assert-True {
  param(
    [Parameter(Mandatory = $true)]
    [bool]$Condition,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )
  if (-not $Condition) {
    throw $Message
  }
}

function Assert-Equal {
  param(
    [AllowEmptyString()]
    [string]$Actual,
    [AllowEmptyString()]
    [string]$Expected,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )
  if ($Actual -cne $Expected) {
    throw "$Message Expected '$Expected', got '$Actual'."
  }
}

function Assert-Throws {
  param(
    [Parameter(Mandatory = $true)]
    [scriptblock]$Body,
    [Parameter(Mandatory = $true)]
    [string]$Pattern
  )
  try {
    & $Body
  } catch {
    if ($_.Exception.Message -notmatch $Pattern) {
      throw "Expected error matching '$Pattern', got '$($_.Exception.Message)'."
    }
    return
  }
  throw "Expected an error matching '$Pattern'."
}

Invoke-Test "environment-backed build roots" {
  $previousChromiumRoot = [Environment]::GetEnvironmentVariable("KWIKEN_CHROMIUM_ROOT")
  $previousDepotToolsRoot = [Environment]::GetEnvironmentVariable("KWIKEN_DEPOT_TOOLS_ROOT")
  try {
    $env:KWIKEN_CHROMIUM_ROOT = "C:\src\test-chromium"
    $env:KWIKEN_DEPOT_TOOLS_ROOT = "C:\src\test-depot-tools"
    Assert-True -Condition ((Get-DefaultChromiumRoot) -eq $env:KWIKEN_CHROMIUM_ROOT) `
      -Message "Chromium environment override was ignored."
    Assert-True -Condition ((Get-DefaultDepotToolsRoot) -eq $env:KWIKEN_DEPOT_TOOLS_ROOT) `
      -Message "depot_tools environment override was ignored."
  } finally {
    [Environment]::SetEnvironmentVariable("KWIKEN_CHROMIUM_ROOT", $previousChromiumRoot)
    [Environment]::SetEnvironmentVariable("KWIKEN_DEPOT_TOOLS_ROOT", $previousDepotToolsRoot)
  }
}

Invoke-Test "build-root safety" {
  $resolved = Resolve-KwikenBuildRoot -Value "C:\src\kwiken-test" `
    -DefaultValue "C:\unused" -Name "TestRoot"
  Assert-True -Condition ($resolved -eq "C:\src\kwiken-test") `
    -Message "Absolute root normalization changed the path."
  Assert-Throws -Body {
    Resolve-KwikenBuildRoot -Value "C:\src\has spaces" `
      -DefaultValue "C:\unused" -Name "TestRoot"
  } -Pattern "must not contain whitespace"
  Assert-Throws -Body {
    Resolve-KwikenBuildRoot -Value "C:\" `
      -DefaultValue "C:\unused" -Name "TestRoot"
  } -Pattern "not a drive root"
  Assert-Throws -Body {
    Resolve-KwikenBuildRoot -Value "C:\src\kwiken-*" `
      -DefaultValue "C:\unused" -Name "TestRoot"
  } -Pattern "wildcard"
}

Invoke-Test "build roots cannot overlap" {
  Assert-DistinctBuildRoots -ChromiumRoot "C:\src\chromium" `
    -DepotToolsRoot "C:\src\depot_tools"
  Assert-Throws -Body {
    Assert-DistinctBuildRoots -ChromiumRoot "C:\src\chromium" `
      -DepotToolsRoot "C:\src\chromium\depot_tools"
  } -Pattern "non-overlapping"
}

Invoke-Test "pinned tool revisions are valid" {
  Assert-True -Condition ($script:Revision -match '^[0-9a-f]{40}$') `
    -Message "Chromium revision is not a 40-character hash."
  Assert-True -Condition ($script:DepotToolsRevision -match '^[0-9a-f]{40}$') `
    -Message "depot_tools revision is not a 40-character hash."
  Assert-True -Condition ($script:ExpectedSourceDeltaSha256 -match '^[0-9a-f]{64}$') `
    -Message "Expected source-delta fingerprint is not a SHA-256 hash."
}

Invoke-Test "build environment is restorable" {
  $outerSnapshot = New-ChromiumBuildEnvironmentSnapshot
  try {
    $env:GIT_CONFIG_COUNT = "1"
    $env:GIT_CONFIG_KEY_0 = "kwiken.test"
    $env:GIT_CONFIG_VALUE_0 = "before"
    Remove-Item -LiteralPath "Env:GIT_CONFIG_KEY_5" -ErrorAction SilentlyContinue
    $snapshot = New-ChromiumBuildEnvironmentSnapshot
    Set-ChromiumGitEnvironment
    Restore-ChromiumBuildEnvironment -Snapshot $snapshot
    Assert-True -Condition ($env:GIT_CONFIG_COUNT -eq "1") `
      -Message "Git config count was not restored."
    Assert-True -Condition ($env:GIT_CONFIG_KEY_0 -eq "kwiken.test") `
      -Message "Existing Git config key was not restored."
    Assert-True -Condition ($env:GIT_CONFIG_VALUE_0 -eq "before") `
      -Message "Existing Git config value was not restored."
    Assert-True -Condition ($null -eq [Environment]::GetEnvironmentVariable(
        "GIT_CONFIG_KEY_5",
        [EnvironmentVariableTarget]::Process
      )) -Message "Absent Git config variables were not removed."
  } finally {
    Restore-ChromiumBuildEnvironment -Snapshot $outerSnapshot
  }
}

Invoke-Test "depot_tools is first on PATH" {
  $previousPath = $env:PATH
  try {
    $env:PATH = "C:\Windows\System32;C:\src\depot_tools;C:\Tools;C:\src\depot_tools\"
    Set-DepotToolsPath -DepotToolsRoot "C:\src\depot_tools"
    $entries = @($env:PATH -split ';')
    Assert-True -Condition ($entries[0] -eq "C:\src\depot_tools") `
      -Message "depot_tools was not moved to the front of PATH."
    $matches = @($entries | Where-Object {
      $_.TrimEnd('\').Equals("C:\src\depot_tools", [StringComparison]::OrdinalIgnoreCase)
    })
    Assert-True -Condition ($matches.Count -eq 1) `
      -Message "Duplicate depot_tools PATH entries were retained."
  } finally {
    $env:PATH = $previousPath
  }
}

Invoke-Test "SDK version detection" {
  $rcPath = Get-WindowsSdkRcPath
  $version = Get-ProductVersion -Path $rcPath
  Assert-True -Condition ($version -ge $script:RequiredWindowsSdkVersion) `
    -Message "The installed SDK is older than the pinned Chromium requirement."
}

Invoke-Test "batch runner propagates exit codes" {
  Invoke-BatchFile -Path $env:ComSpec -Arguments @("/d", "/c", "exit", "0")
  Assert-Throws -Body {
    Invoke-BatchFile -Path $env:ComSpec -Arguments @("/d", "/c", "exit", "7")
  } -Pattern "exit code 7"
}

Invoke-Test "Windows command-line arguments are quoted losslessly" {
  Assert-Equal -Actual (ConvertTo-WindowsCommandLineArgument -Argument "") `
    -Expected '""' -Message "An empty argument was not preserved."
  Assert-Equal -Actual (ConvertTo-WindowsCommandLineArgument -Argument "plain") `
    -Expected "plain" -Message "A plain argument was changed."
  Assert-Equal `
    -Actual (ConvertTo-WindowsCommandLineArgument -Argument 'C:\Profile Root\') `
    -Expected '"C:\Profile Root\\"' `
    -Message "Trailing backslashes were not escaped before the closing quote."
  Assert-Equal `
    -Actual (ConvertTo-WindowsCommandLineArgument -Argument '--label=Kwiken "Preview"') `
    -Expected '"--label=Kwiken \"Preview\""' `
    -Message "Embedded quotes were not escaped."
}

Invoke-Test "process launcher preserves argument boundaries" {
  $probeRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("Kwiken launch test " + [Guid]::NewGuid().ToString("N"))
  $probePath = Join-Path $probeRoot "argument probe.ps1"
  $probeValue = 'value with "quotes" and trailing\'
  [void][IO.Directory]::CreateDirectory($probeRoot)
  try {
    $probeScript = @'
param([string]$Value)
$expected = 'value with "quotes" and trailing\'
if ($Value -ceq $expected) { exit 0 }
exit 9
'@
    [IO.File]::WriteAllText($probePath, $probeScript, [Text.UTF8Encoding]::new($false))
    $engineName = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh.exe" } else { "powershell.exe" }
    $enginePath = Join-Path $PSHOME $engineName
    $process = Start-KwikenBrowserProcess -FilePath $enginePath -Arguments @(
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", $probePath,
      $probeValue
    ) -WorkingDirectory $probeRoot
    if (-not $process.WaitForExit(15000)) {
      $process.Kill()
      throw "Argument probe did not exit within 15 seconds."
    }
    Assert-True -Condition ($process.ExitCode -eq 0) `
      -Message "The child process did not receive the exact quoted argument."
  } finally {
    if (Test-Path -LiteralPath $probePath) {
      [IO.File]::Delete($probePath)
    }
    if (Test-Path -LiteralPath $probeRoot) {
      [IO.Directory]::Delete($probeRoot)
    }
  }
}

Invoke-Test "browser startup rejects immediate exits" {
  $process = Start-KwikenBrowserProcess -FilePath $env:ComSpec `
    -Arguments @("/d", "/c", "exit 7") -WorkingDirectory $env:TEMP
  Assert-Throws -Body {
    Wait-KwikenBrowserStartup -Process $process `
      -StartupTimeoutSeconds 2 -StabilityMilliseconds 100
  } -Pattern "exit code 7"
}

Invoke-Test "source patches are discovered and applied in lexical order" {
  $applyScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) `
    "scripts\apply-patches.ps1"
  $applyScript = [IO.File]::ReadAllText($applyScriptPath)
  Assert-True -Condition ($applyScript -match 'Get-ChildItem[\s\S]+"\*\.patch"') `
    -Message "apply-patches.ps1 does not discover the complete patch series."
  Assert-True -Condition ($applyScript -match 'Sort-Object\s+-Property\s+Name') `
    -Message "The patch series is not applied in deterministic lexical order."
  Assert-True -Condition ($applyScript -match 'foreach\s*\(\$patch\s+in\s+\$patchPaths\)') `
    -Message "The discovered patch series is not iterated."
  Assert-True -Condition ($applyScript -notmatch 'patches\\0001-kwiken-browser\.patch') `
    -Message "apply-patches.ps1 is still hard-coded to the baseline patch."
  Assert-True -Condition (
      $applyScript -match 'Get-ChromiumSourceDeltaSha256[\s\S]+ExpectedSourceDeltaSha256[\s\S]+already applied') `
    -Message "apply-patches.ps1 cannot recognize the complete reviewed stack on a rerun."
}

Invoke-Test "runtime export fingerprints the complete patch series" {
  $exportScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) `
    "scripts\export-runtime.ps1"
  $exportScript = [IO.File]::ReadAllText($exportScriptPath)
  Assert-True -Condition ($exportScript -match 'Get-ChildItem[\s\S]+"\*\.patch"') `
    -Message "export-runtime.ps1 does not discover the complete patch series."
  Assert-True -Condition ($exportScript -match 'Sort-Object\s+-Property\s+Name') `
    -Message "The runtime export patch series is not ordered deterministically."
  Assert-True -Condition (
      $exportScript -match '\$provenanceInputPaths\.Add\(\$patch\.FullName\)') `
    -Message "The complete patch series is not included in runtime provenance."
  Assert-True -Condition (
      $exportScript -notmatch 'patches\\0001-kwiken-browser\.patch') `
    -Message "export-runtime.ps1 is still hard-coded to the baseline patch."
  Assert-True -Condition (
      $exportScript -notmatch 'apply\s+--reverse\s+--check[\s\S]+\$patchPath') `
    -Message "export-runtime.ps1 still reverse-checks one patch against the final stack."
}

Invoke-Test "runtime export isolates generated Python bytecode" {
  $exportScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) `
    "scripts\export-runtime.ps1"
  $exportScript = [IO.File]::ReadAllText($exportScriptPath)
  foreach ($required in @(
      'PYTHONDONTWRITEBYTECODE',
      'PYTHONPYCACHEPREFIX',
      'Assert-InstalledPythonMatchesAuthenticatedRuntime'
    )) {
    Assert-True -Condition ($exportScript.Contains($required)) `
      -Message "Runtime export Python isolation is missing $required."
  }
  Assert-True -Condition (
      $exportScript -match '\(\?:\^\|/\)__pycache__/\[\^/\]\+\\\.pyc\$') `
    -Message "Runtime export does not narrowly allow generated Python bytecode."
}

Invoke-Test "all PowerShell scripts parse" {
  $scripts = Get-ChildItem (Join-Path (Split-Path -Parent $PSScriptRoot) "scripts\*.ps1")
  foreach ($scriptFile in $scripts) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
      $scriptFile.FullName,
      [ref]$tokens,
      [ref]$errors
    ) | Out-Null
    $errorMessages = @($errors | ForEach-Object { $_.Message })
    Assert-True -Condition ($errors.Count -eq 0) `
      -Message "$($scriptFile.Name) has parser errors: $($errorMessages -join '; ')"
  }
}

if ($failures.Count -gt 0) {
  throw "Build-script tests failed:`n$($failures -join [Environment]::NewLine)"
}
Write-Output "All build-script tests passed."
