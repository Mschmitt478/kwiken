$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:ForkRoot = Split-Path -Parent $PSScriptRoot
$script:RepoRoot = Split-Path -Parent $script:ForkRoot
$script:Version = (Get-Content (Join-Path $script:ForkRoot "VERSION") -Raw).Trim()
$script:PackageRevision = (Get-Content (Join-Path $script:ForkRoot "PACKAGE_REVISION") -Raw).Trim()
$script:ReleaseVersion = "$script:Version-r$script:PackageRevision"
$script:Revision = (Get-Content (Join-Path $script:ForkRoot "REVISION") -Raw).Trim()
$script:DepotToolsRevision = (Get-Content (Join-Path $script:ForkRoot "DEPOT_TOOLS_REVISION") -Raw).Trim()
$script:ExpectedSourceDeltaSha256 = (
  Get-Content (Join-Path $script:ForkRoot "SOURCE_DELTA_SHA256") -Raw
).Trim().ToLowerInvariant()
$script:RequiredVisualStudioMajorVersion = 18
$script:RequiredWindowsSdkVersion = [Version]"10.0.26100.7705"
$script:RequiredWindowsDebuggerVersion = [Version]"10.0.26100.3323"

function Get-DefaultChromiumRoot {
  $configuredRoot = [Environment]::GetEnvironmentVariable("KWIKEN_CHROMIUM_ROOT")
  if (-not [string]::IsNullOrWhiteSpace($configuredRoot)) {
    return $configuredRoot
  }
  return "C:\src\kwiken-chromium"
}

function Get-DefaultDepotToolsRoot {
  $configuredRoot = [Environment]::GetEnvironmentVariable("KWIKEN_DEPOT_TOOLS_ROOT")
  if (-not [string]::IsNullOrWhiteSpace($configuredRoot)) {
    return $configuredRoot
  }
  return "C:\src\depot_tools"
}

function Resolve-KwikenBuildRoot {
  param(
    [string]$Value,
    [Parameter(Mandatory = $true)]
    [string]$DefaultValue,
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    $Value = $DefaultValue
  }

  $expandedValue = [Environment]::ExpandEnvironmentVariables($Value)
  if ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($expandedValue)) {
    throw "$Name must not contain wildcard characters: $expandedValue"
  }
  if (-not [IO.Path]::IsPathRooted($expandedValue)) {
    $expandedValue = Join-Path (Get-Location).Path $expandedValue
  }

  $resolvedRoot = [IO.Path]::GetFullPath($expandedValue)
  if ($resolvedRoot -match '\s') {
    throw "$Name must not contain whitespace because Chromium's Windows tools do not reliably support it: $resolvedRoot"
  }
  if ($resolvedRoot -eq [IO.Path]::GetPathRoot($resolvedRoot)) {
    throw "$Name must be a dedicated directory, not a drive root: $resolvedRoot"
  }

  # gclient -D can delete directories. Reject junction/symlink-backed roots so
  # its lexical checkout boundary cannot resolve into an unrelated location.
  $candidate = $resolvedRoot
  while (-not [string]::IsNullOrWhiteSpace($candidate)) {
    if (Test-Path -LiteralPath $candidate) {
      $item = Get-Item -LiteralPath $candidate -Force
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Name must not use a junction or symbolic link: $candidate"
      }
    }
    $parent = Split-Path -Parent $candidate
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $candidate) {
      break
    }
    $candidate = $parent
  }
  return $resolvedRoot.TrimEnd('\')
}

function Assert-DistinctBuildRoots {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ChromiumRoot,
    [Parameter(Mandatory = $true)]
    [string]$DepotToolsRoot
  )

  $chromiumPrefix = $ChromiumRoot.TrimEnd('\') + '\'
  $depotToolsPrefix = $DepotToolsRoot.TrimEnd('\') + '\'
  if ($ChromiumRoot.Equals($DepotToolsRoot, [StringComparison]::OrdinalIgnoreCase) -or
      $chromiumPrefix.StartsWith($depotToolsPrefix, [StringComparison]::OrdinalIgnoreCase) -or
      $depotToolsPrefix.StartsWith($chromiumPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "ChromiumRoot and DepotToolsRoot must be separate, non-overlapping directories."
  }
}

function Get-VsWherePath {
  $candidates = @(
    (Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"),
    (Join-Path $env:ProgramFiles "Microsoft Visual Studio\Installer\vswhere.exe")
  )
  return $candidates |
    Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1
}

function Get-QualifyingVisualStudioInstallations {
  $vsWhere = Get-VsWherePath
  if (-not $vsWhere) {
    return @()
  }

  $arguments = @(
    "-all",
    "-products", "*",
    "-version", "[$script:RequiredVisualStudioMajorVersion.0,$($script:RequiredVisualStudioMajorVersion + 1).0)",
    "-requires",
    "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
    "Microsoft.VisualStudio.Component.VC.ATLMFC",
    "-format", "json"
  )
  $json = (& $vsWhere @arguments) -join [Environment]::NewLine
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
    return @()
  }
  $parsedInstallations = $json | ConvertFrom-Json
  foreach ($installation in $parsedInstallations) {
    Write-Output $installation
  }
}

function Resolve-VisualStudioRoot {
  param([string]$VisualStudioRoot)

  if ([string]::IsNullOrWhiteSpace($VisualStudioRoot)) {
    $VisualStudioRoot = [Environment]::GetEnvironmentVariable("KWIKEN_VISUAL_STUDIO_ROOT")
  }

  $installations = @(Get-QualifyingVisualStudioInstallations)
  if (-not [string]::IsNullOrWhiteSpace($VisualStudioRoot)) {
    $requestedRoot = [IO.Path]::GetFullPath(
      [Environment]::ExpandEnvironmentVariables($VisualStudioRoot)
    ).TrimEnd('\')
    $installations = @($installations | Where-Object {
      ([IO.Path]::GetFullPath($_.installationPath)).TrimEnd('\').Equals(
        $requestedRoot,
        [StringComparison]::OrdinalIgnoreCase
      )
    })
  }

  $installation = $installations |
    Sort-Object { [Version]$_.installationVersion } -Descending |
    Select-Object -First 1
  if (-not $installation) {
    throw "Visual Studio 2026 with x64/x86 C++ tools and ATL/MFC was not found. Install Visual Studio 2026 Build Tools (or a full edition) with Desktop development with C++ and Microsoft.VisualStudio.Component.VC.ATLMFC."
  }

  $resolvedRoot = ([IO.Path]::GetFullPath($installation.installationPath)).TrimEnd('\')
  $vsDevCmd = Join-Path $resolvedRoot "Common7\Tools\VsDevCmd.bat"
  if (-not (Test-Path -LiteralPath $vsDevCmd)) {
    throw "Visual Studio's developer environment was not found at $vsDevCmd."
  }
  return $resolvedRoot
}

function Get-ProductVersion {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }
  $rawVersion = (Get-Item -LiteralPath $Path).VersionInfo.ProductVersion
  $match = [regex]::Match($rawVersion, '\d+\.\d+\.\d+\.\d+')
  if (-not $match.Success) {
    return $null
  }
  return [Version]$match.Value
}

function Get-WindowsSdkRcPath {
  $sdkRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
  if (-not (Test-Path -LiteralPath $sdkRoot)) {
    return $null
  }
  return Get-ChildItem -LiteralPath $sdkRoot -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
    Sort-Object { [Version]$_.Name } -Descending |
    ForEach-Object { Join-Path $_.FullName "x64\rc.exe" } |
    Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1
}

function Get-WindowsDebuggerPath {
  $candidates = @(
    (Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Debuggers\x64\cdb.exe"),
    (Join-Path $env:ProgramFiles "Windows Kits\10\Debuggers\x64\cdb.exe")
  )
  return $candidates |
    Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1
}

function New-PrerequisiteResult {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [bool]$Passed,
    [Parameter(Mandatory = $true)]
    [string]$Detail,
    [string]$Remediation = ""
  )

  return [pscustomobject]@{
    Name = $Name
    Passed = $Passed
    Detail = $Detail
    Remediation = $Remediation
  }
}

function Test-ChromiumBuildPrerequisites {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ChromiumRoot,
    [Parameter(Mandatory = $true)]
    [string]$DepotToolsRoot,
    [string]$VisualStudioRoot,
    [ValidateRange(1, 500)]
    [int]$MinimumFreeSpaceGB = 100,
    [switch]$RequireDepotTools
  )

  $results = [Collections.Generic.List[object]]::new()
  $osVersion = [Environment]::OSVersion.Version
  $osArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture
  $isWindowsX64 = $env:OS -eq "Windows_NT" -and
    $osVersion -ge [Version]"10.0.19041" -and
    $osArchitecture -eq [Runtime.InteropServices.Architecture]::X64
  $results.Add((New-PrerequisiteResult -Name "Windows x64" -Passed $isWindowsX64 `
    -Detail "$([Environment]::OSVersion.VersionString), $osArchitecture" `
    -Remediation "Use an x64 Windows 10 2004 or newer host."))

  $memoryGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
  $results.Add((New-PrerequisiteResult -Name "Memory" -Passed ($memoryGB -ge 8) `
    -Detail "$memoryGB GB installed" `
    -Remediation "Chromium requires at least 8 GB; more than 16 GB is strongly recommended."))

  $git = Get-Command git.exe -ErrorAction SilentlyContinue
  $results.Add((New-PrerequisiteResult -Name "Git" -Passed ($null -ne $git) `
    -Detail $(if ($git) { $git.Source } else { "Not found" }) `
    -Remediation "Install current Git for Windows."))

  try {
    Assert-DistinctBuildRoots -ChromiumRoot $ChromiumRoot -DepotToolsRoot $DepotToolsRoot
    $results.Add((New-PrerequisiteResult -Name "Build roots" -Passed $true `
      -Detail "Chromium=$ChromiumRoot; depot_tools=$DepotToolsRoot"))
  } catch {
    $results.Add((New-PrerequisiteResult -Name "Build roots" -Passed $false `
      -Detail $_.Exception.Message `
      -Remediation "Use separate short paths without spaces, such as C:\src\kwiken-chromium and C:\src\depot_tools."))
  }

  try {
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($ChromiumRoot))
    $freeGB = [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
    $diskPassed = $drive.DriveFormat -eq "NTFS" -and $freeGB -ge $MinimumFreeSpaceGB
    $results.Add((New-PrerequisiteResult -Name "Checkout disk" -Passed $diskPassed `
      -Detail "$($drive.Name) $($drive.DriveFormat), $freeGB GB free" `
      -Remediation "Use NTFS with at least $MinimumFreeSpaceGB GB free."))
  } catch {
    $results.Add((New-PrerequisiteResult -Name "Checkout disk" -Passed $false `
      -Detail $_.Exception.Message `
      -Remediation "Choose an existing local NTFS drive."))
  }

  try {
    $resolvedVisualStudioRoot = Resolve-VisualStudioRoot -VisualStudioRoot $VisualStudioRoot
    $results.Add((New-PrerequisiteResult -Name "Visual Studio 2026" -Passed $true `
      -Detail $resolvedVisualStudioRoot))
  } catch {
    $results.Add((New-PrerequisiteResult -Name "Visual Studio 2026" -Passed $false `
      -Detail $_.Exception.Message `
      -Remediation "Install the VS 2026 Desktop C++ workload plus ATL/MFC."))
  }

  $rcPath = Get-WindowsSdkRcPath
  $sdkVersion = if ($rcPath) { Get-ProductVersion -Path $rcPath } else { $null }
  $sdkPassed = $null -ne $sdkVersion -and $sdkVersion -ge $script:RequiredWindowsSdkVersion
  $sdkDetail = if ($sdkVersion) { "$sdkVersion at $rcPath" } else { "Compatible rc.exe not found" }
  $results.Add((New-PrerequisiteResult -Name "Windows 11 SDK" -Passed $sdkPassed `
    -Detail $sdkDetail `
    -Remediation "Install Windows 11 SDK $script:RequiredWindowsSdkVersion or newer."))

  $debuggerPath = Get-WindowsDebuggerPath
  $debuggerVersion = if ($debuggerPath) { Get-ProductVersion -Path $debuggerPath } else { $null }
  $debuggerPassed = $null -ne $debuggerVersion -and $debuggerVersion -ge $script:RequiredWindowsDebuggerVersion
  $debuggerDetail = if ($debuggerVersion) { "$debuggerVersion at $debuggerPath" } else { "cdb.exe not found" }
  $results.Add((New-PrerequisiteResult -Name "SDK Debugging Tools" -Passed $debuggerPassed `
    -Detail $debuggerDetail `
    -Remediation "Install the Windows SDK Debugging Tools feature ($script:RequiredWindowsDebuggerVersion or newer)."))

  if ($RequireDepotTools) {
    $requiredDepotToolsFiles = @(
      ".git",
      "fetch.bat",
      "gclient.bat",
      "gn.bat",
      "autoninja.bat",
      "git.bat",
      "python3.bat",
      "vpython3.bat"
    )
    $missingDepotToolsFiles = @($requiredDepotToolsFiles | Where-Object {
      -not (Test-Path -LiteralPath (Join-Path $DepotToolsRoot $_))
    })
    $depotToolsPassed = $missingDepotToolsFiles.Count -eq 0
    $depotToolsDetail = if ($depotToolsPassed) {
      $actualDepotToolsRevision = (& git -C $DepotToolsRoot rev-parse HEAD).Trim()
      $depotToolsChanges = & git -C $DepotToolsRoot status --porcelain --untracked-files=no
      if ($LASTEXITCODE -ne 0) {
        "Could not inspect depot_tools"
      } elseif ($depotToolsChanges) {
        "Tracked changes: $($depotToolsChanges -join '; ')"
      } else {
        $actualDepotToolsRevision
      }
    } else {
      "Missing: $($missingDepotToolsFiles -join ', ')"
    }
    $depotToolsPassed = $depotToolsPassed -and $depotToolsDetail -eq $script:DepotToolsRevision
    $results.Add((New-PrerequisiteResult -Name "Pinned depot_tools" -Passed $depotToolsPassed `
      -Detail $depotToolsDetail `
      -Remediation "Run bootstrap.ps1 to install depot_tools revision $script:DepotToolsRevision."))
  }

  return $results.ToArray()
}

function Assert-ChromiumBuildPrerequisites {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ChromiumRoot,
    [Parameter(Mandatory = $true)]
    [string]$DepotToolsRoot,
    [string]$VisualStudioRoot,
    [ValidateRange(1, 500)]
    [int]$MinimumFreeSpaceGB = 100,
    [switch]$RequireDepotTools
  )

  $results = @(Test-ChromiumBuildPrerequisites @PSBoundParameters)
  $results |
    Select-Object Name,@{Name="Status";Expression={ if ($_.Passed) { "OK" } else { "MISSING" } }},Detail |
    Format-Table -AutoSize -Wrap |
    Out-Host

  $failures = @($results | Where-Object { -not $_.Passed })
  if ($failures.Count -gt 0) {
    $remediation = $failures | ForEach-Object { "- $($_.Name): $($_.Remediation)" }
    throw "Chromium build preflight failed:`n$($remediation -join [Environment]::NewLine)"
  }
  return $results
}

function Assert-DepotToolsCheckout {
  param(
    [Parameter(Mandatory = $true)]
    [string]$DepotToolsRoot
  )

  if (-not (Test-Path -LiteralPath (Join-Path $DepotToolsRoot ".git"))) {
    throw "depot_tools was not found at $DepotToolsRoot. Run bootstrap.ps1 first."
  }
  $actualRevision = (& git -C $DepotToolsRoot rev-parse HEAD).Trim()
  if ($LASTEXITCODE -ne 0 -or $actualRevision -ne $script:DepotToolsRevision) {
    throw "Expected depot_tools revision $script:DepotToolsRevision but found $actualRevision. Run bootstrap.ps1."
  }
  $trackedChanges = & git -C $DepotToolsRoot status --porcelain --untracked-files=no
  if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect the depot_tools checkout at $DepotToolsRoot."
  }
  if ($trackedChanges) {
    throw "The pinned depot_tools checkout has tracked changes: $($trackedChanges -join '; ')"
  }
}

function Initialize-DepotTools {
  param(
    [Parameter(Mandatory = $true)]
    [string]$DepotToolsRoot
  )

  Assert-DepotToolsCheckout -DepotToolsRoot $DepotToolsRoot
  Invoke-BatchFile -Path (Join-Path $DepotToolsRoot "cipd_bin_setup.bat")
  Invoke-BatchFile -Path (Join-Path $DepotToolsRoot "bootstrap\win_tools.bat")

  foreach ($requiredFile in @("git.bat", "python3.bat", "vpython3.bat")) {
    $requiredPath = Join-Path $DepotToolsRoot $requiredFile
    if (-not (Test-Path -LiteralPath $requiredPath)) {
      throw "depot_tools bootstrap did not create $requiredPath."
    }
  }
}

function New-ChromiumBuildEnvironmentSnapshot {
  $names = [Collections.Generic.List[string]]::new()
  foreach ($name in @(
      "PATH",
      "DEPOT_TOOLS_UPDATE",
      "DEPOT_TOOLS_WIN_TOOLCHAIN",
      "vs2026_install",
      "GIT_CONFIG_COUNT"
    )) {
    $names.Add($name)
  }
  for ($index = 0; $index -lt 32; $index++) {
    $names.Add("GIT_CONFIG_KEY_$index")
    $names.Add("GIT_CONFIG_VALUE_$index")
  }

  $values = @{}
  foreach ($name in $names) {
    $values[$name] = [Environment]::GetEnvironmentVariable(
      $name,
      [EnvironmentVariableTarget]::Process
    )
  }
  return $values
}

function Restore-ChromiumBuildEnvironment {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Snapshot
  )

  foreach ($entry in $Snapshot.GetEnumerator()) {
    if ($null -eq $entry.Value) {
      Remove-Item -LiteralPath "Env:$($entry.Key)" -ErrorAction SilentlyContinue
    } else {
      [Environment]::SetEnvironmentVariable(
        $entry.Key,
        $entry.Value,
        [EnvironmentVariableTarget]::Process
      )
    }
  }
}

function Set-ChromiumGitEnvironment {
  # Keep Chromium's required Git behavior local to this script and its child
  # processes instead of rewriting the user's global Git configuration.
  $env:GIT_CONFIG_COUNT = "5"
  $env:GIT_CONFIG_KEY_0 = "core.autocrlf"
  $env:GIT_CONFIG_VALUE_0 = "false"
  $env:GIT_CONFIG_KEY_1 = "core.filemode"
  $env:GIT_CONFIG_VALUE_1 = "false"
  $env:GIT_CONFIG_KEY_2 = "core.longpaths"
  $env:GIT_CONFIG_VALUE_2 = "true"
  $env:GIT_CONFIG_KEY_3 = "core.fscache"
  $env:GIT_CONFIG_VALUE_3 = "true"
  $env:GIT_CONFIG_KEY_4 = "core.preloadindex"
  $env:GIT_CONFIG_VALUE_4 = "true"
}

function Set-DepotToolsPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$DepotToolsRoot
  )

  $pathEntries = @($env:PATH -split ';' | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_) -and
    -not $_.TrimEnd('\').Equals(
      $DepotToolsRoot.TrimEnd('\'),
      [StringComparison]::OrdinalIgnoreCase
    )
  })
  $env:PATH = (@($DepotToolsRoot) + $pathEntries) -join ';'
}

function Set-ChromiumBuildEnvironment {
  param(
    [Parameter(Mandatory = $true)]
    [string]$DepotToolsRoot,
    [string]$VisualStudioRoot
  )

  Assert-DepotToolsCheckout -DepotToolsRoot $DepotToolsRoot
  $resolvedVisualStudioRoot = Resolve-VisualStudioRoot -VisualStudioRoot $VisualStudioRoot
  $env:DEPOT_TOOLS_UPDATE = "0"
  $env:DEPOT_TOOLS_WIN_TOOLCHAIN = "0"
  $env:vs2026_install = $resolvedVisualStudioRoot
  Set-ChromiumGitEnvironment
  Set-DepotToolsPath -DepotToolsRoot $DepotToolsRoot
}

function Assert-ChromiumCheckout {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ChromiumRoot
  )

  $sourceRoot = Join-Path $ChromiumRoot "src"
  if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot "chrome\VERSION"))) {
    throw "Chromium source was not found at $sourceRoot. Run bootstrap.ps1 first."
  }

  $actualRevision = (& git -C $sourceRoot rev-parse HEAD).Trim()
  if ($LASTEXITCODE -ne 0 -or $actualRevision -ne $script:Revision) {
    throw "Expected Chromium revision $script:Revision but found $actualRevision."
  }

  return $sourceRoot
}

function Get-ChromiumSourceDeltaSha256 {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot
  )

  $git = Get-Command git.exe -ErrorAction Stop
  $startInfo = New-Object Diagnostics.ProcessStartInfo
  $startInfo.FileName = $git.Source
  $startInfo.WorkingDirectory = $SourceRoot
  $startInfo.Arguments = "-c color.ui=false diff --name-only -z --no-ext-diff --no-textconv --no-renames --ignore-submodules=all $script:Revision -- ."
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true

  $process = New-Object Diagnostics.Process
  $process.StartInfo = $startInfo
  $pathBytes = [IO.MemoryStream]::new()
  try {
    if (-not $process.Start()) {
      throw "Could not start Git to fingerprint the Chromium source delta."
    }
    $process.StandardOutput.BaseStream.CopyTo($pathBytes)
    $errorText = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
      throw "Could not fingerprint the Chromium source delta: $errorText"
    }
  } finally {
    $process.Dispose()
  }

  $utf8 = [Text.UTF8Encoding]::new($false, $true)
  $pathText = $utf8.GetString($pathBytes.ToArray())
  $pathBytes.Dispose()
  $paths = @($pathText.Split(
      @([char]0),
      [StringSplitOptions]::RemoveEmptyEntries
    ))
  [Array]::Sort($paths, [StringComparer]::Ordinal)

  # Hash a canonical, content-addressed manifest instead of Git's human-facing
  # patch rendering. This is stable across color/prefix/context/user settings.
  $manifest = [IO.MemoryStream]::new()
  $sha256 = [Security.Cryptography.SHA256]::Create()
  try {
    foreach ($relativePath in $paths) {
      $filePath = Join-Path $SourceRoot $relativePath.Replace('/', '\')
      if (Test-Path -LiteralPath $filePath -PathType Leaf) {
        $file = Get-Item -LiteralPath $filePath
        $fileHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $record = "$relativePath$([char]0)$($file.Length)$([char]0)$fileHash`n"
      } elseif (Test-Path -LiteralPath $filePath) {
        throw "Unsupported non-file entry in the Chromium source delta: $relativePath"
      } else {
        $record = "$relativePath$([char]0)deleted`n"
      }
      $recordBytes = $utf8.GetBytes($record)
      $manifest.Write($recordBytes, 0, $recordBytes.Length)
    }
    $manifest.Position = 0
    $hashBytes = $sha256.ComputeHash($manifest)
    return -join ($hashBytes | ForEach-Object { $_.ToString("x2") })
  } finally {
    $sha256.Dispose()
    $manifest.Dispose()
  }
}

function Assert-KwikenSourceDelta {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot
  )

  $actualHash = Get-ChromiumSourceDeltaSha256 -SourceRoot $SourceRoot
  if ($actualHash -ne $script:ExpectedSourceDeltaSha256) {
    throw "The Chromium source delta is not the reviewed Kwiken delta. Expected $script:ExpectedSourceDeltaSha256 but found $actualHash."
  }
  return $actualHash
}

function Invoke-BatchFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
  )

  & $Path @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$Path failed with exit code $LASTEXITCODE."
  }
}
