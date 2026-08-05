$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$forkRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $forkRoot "scripts\export-runtime.ps1"
. (Join-Path $forkRoot "scripts\launch-support.ps1")
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  $scriptPath,
  [ref]$tokens,
  [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
  throw "export-runtime.ps1 has parser errors: $($parseErrors -join '; ')"
}

function Import-ExportFunction {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  $definition = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $Name
    }, $true))
  if ($definition.Count -ne 1) {
    throw "Expected one $Name definition, found $($definition.Count)."
  }
  Set-Item -Path "Function:\global:$Name" `
    -Value $definition[0].Body.GetScriptBlock()
}

function Assert-Throws {
  param(
    [Parameter(Mandatory = $true)]
    [scriptblock]$Action,
    [Parameter(Mandatory = $true)]
    [string]$Description
  )

  try {
    & $Action
  } catch {
    return
  }
  throw "Expected failure: $Description"
}

Import-ExportFunction -Name "Test-SafeWindowsArchivePath"
Import-ExportFunction -Name "Assert-SafeSevenZipListing"
Import-ExportFunction -Name "Get-LowerSha256"
Import-ExportFunction -Name "Initialize-KwikenPathInterop"
Import-ExportFunction -Name "Get-HandleResolvedPath"
Import-ExportFunction -Name "Assert-PathOutsideRoot"
Import-ExportFunction -Name "Get-PinnedDepotToolsPython"
Import-ExportFunction -Name "Assert-NoReparseAncestors"
Import-ExportFunction -Name "Assert-NoReparsePath"
Import-ExportFunction -Name "Copy-FileSnapshot"
Import-ExportFunction -Name "Get-DirectoryTreeSha256"
Import-ExportFunction -Name "Assert-InstalledPythonMatchesAuthenticatedRuntime"
Import-ExportFunction -Name "Copy-DirectorySnapshot"
Import-ExportFunction -Name "Assert-PythonSnapshot"
Import-ExportFunction -Name "Initialize-KwikenJobInterop"
Import-ExportFunction -Name "Stop-ProcessTreeChecked"
Import-ExportFunction -Name "Invoke-DirectProcess"
Import-ExportFunction -Name "Get-PeMachine"
Import-ExportFunction -Name "Assert-Amd64Pe"
Import-ExportFunction -Name "Test-SameProfileProcess"
Import-ExportFunction -Name "Initialize-KwikenPrivateDirectoryInterop"
Import-ExportFunction -Name "New-PrivateDirectory"
Import-ExportFunction -Name "Get-AccessRuleFingerprint"
Import-ExportFunction -Name "Set-PublicationAclForAtomicMove"
Import-ExportFunction -Name "Assert-PublicationAclAfterAtomicMove"
Import-ExportFunction -Name "Remove-ExportStagingDirectory"

$script:Version = "150.0.7871.186"
$script:MaximumRuntimeFiles = 10000
$script:MaximumRuntimeBytes = [Int64]4 * 1024 * 1024 * 1024
$script:ExpectedPeMachine = 0x8664

$testDepotTools = "C:\src\depot_tools"
if (Test-Path -LiteralPath $testDepotTools -PathType Container) {
  $pinnedPython = Get-PinnedDepotToolsPython -DepotToolsRoot $testDepotTools
  if ($pinnedPython.CipdPackage -cne
      "infra/3pp/tools/cpython3/windows-amd64" -or
      -not $pinnedPython.CipdInstance) {
    throw "Pinned depot_tools Python CIPD identity was not validated."
  }
}

$shellPath = (Get-Process -Id $PID).Path
$directResult = Invoke-DirectProcess -FilePath $shellPath -Arguments @(
  "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "'job-ok'"
) -WorkingDirectory $PSScriptRoot -TimeoutSeconds 10 `
  -Description "job-object direct process test"
if ($directResult.StandardOutput.Trim() -ne "job-ok") {
  throw "Direct process output was not captured through the job object."
}
if ($directResult.StandardError) {
  throw "Quiet direct process produced unexpected stderr: $($directResult.StandardError)"
}
$unicodeExpected = "caf$([char]0x00e9)$([char]0x6f22)"
$unicodeResult = Invoke-DirectProcess -FilePath $shellPath -Arguments @(
  "-NoLogo",
  "-NoProfile",
  "-NonInteractive",
  "-Command",
  '[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);' +
    '[Console]::Out.Write("caf"+[char]0x00e9+[char]0x6f22)'
) -WorkingDirectory $PSScriptRoot -TimeoutSeconds 10 `
  -Description "UTF-8 direct process test"
if ($unicodeResult.StandardOutput -cne $unicodeExpected -or
    $unicodeResult.StandardError) {
  throw "Direct process UTF-8 relay was not byte-faithful."
}
Assert-Throws -Description "job-object timeout" -Action {
  Invoke-DirectProcess -FilePath $shellPath -Arguments @(
    "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 3"
  ) -WorkingDirectory $PSScriptRoot -TimeoutSeconds 1 `
    -Description "job-object timeout test" | Out-Null
}
Assert-Throws -Description "bounded process output" -Action {
  Invoke-DirectProcess -FilePath $shellPath -Arguments @(
    "-NoLogo",
    "-NoProfile",
    "-NonInteractive",
    "-Command",
    "[Console]::Out.Write(('x' * 4096)); Start-Sleep -Seconds 3"
  ) -WorkingDirectory $PSScriptRoot -TimeoutSeconds 10 `
    -Description "bounded process output test" `
    -MaximumStandardOutputBytes 128 | Out-Null
}

$profileRoot = "C:\synthetic\kwiken-profile"
$creationDate = [DateTime]::UtcNow
$profileCandidate = [pscustomobject]@{
  ProcessId = [UInt32]42000
  ParentProcessId = [UInt32]41000
  CreationDate = $creationDate
  Name = "chrome.exe"
  ExecutablePath = "C:\synthetic\chrome.exe"
  CommandLine = "chrome.exe --user-data-dir=$profileRoot --headless=new"
}
$profileCurrent = [pscustomobject]@{
  ProcessId = $profileCandidate.ProcessId
  ParentProcessId = $profileCandidate.ParentProcessId
  CreationDate = $profileCandidate.CreationDate
  Name = $profileCandidate.Name
  ExecutablePath = $profileCandidate.ExecutablePath
  CommandLine = $profileCandidate.CommandLine
}
if (-not (Test-SameProfileProcess -Candidate $profileCandidate `
    -Current $profileCurrent -ProfileRoot $profileRoot)) {
  throw "Profile process identity rejected the same process."
}
$profileCurrent.CreationDate = $creationDate.AddMilliseconds(1)
if (Test-SameProfileProcess -Candidate $profileCandidate `
    -Current $profileCurrent -ProfileRoot $profileRoot) {
  throw "Profile process identity accepted a reused PID."
}
$profileCurrent.CreationDate = $creationDate
$profileCurrent.CommandLine = "chrome.exe --headless=new"
if (Test-SameProfileProcess -Candidate $profileCandidate `
    -Current $profileCurrent -ProfileRoot $profileRoot) {
  throw "Profile process identity accepted the wrong command line."
}

$safe = Test-SafeWindowsArchivePath -Path "Chrome-bin\150.0.7871.186\chrome.dll"
if ($safe -cne "Chrome-bin/150.0.7871.186/chrome.dll") {
  throw "Safe 7z path did not normalize as expected: $safe"
}
foreach ($unsafe in @(
    "..\escape.exe",
    "C:\escape.exe",
    "Chrome-bin\CON.txt",
    "Chrome-bin\CONIN$",
    "Chrome-bin\bad?.dll"
  )) {
  Assert-Throws -Description "unsafe 7z path $unsafe" -Action {
    Test-SafeWindowsArchivePath -Path $unsafe | Out-Null
  }
}

$validListing = @"
7-Zip technical listing
----------
Path = Chrome-bin
Folder = +
Encrypted = -
Size = 0

Path = Chrome-bin\chrome.exe
Folder = -
Encrypted = -
Size = 4096
"@
Assert-SafeSevenZipListing -Listing $validListing

$pinnedListing = @"
7-Zip technical listing
----------
Path = Chrome-bin
Attributes = D
Encrypted = -
Size = 0

Path = Chrome-bin\chrome.exe
Attributes = A
Encrypted = -
Size = 4096
"@
Assert-SafeSevenZipListing -Listing $pinnedListing

$conflictingDirectoryListing = @"
7-Zip technical listing
----------
Path = Chrome-bin
Folder = +
Attributes = A
Encrypted = -
Size = 0
"@
Assert-Throws -Description "conflicting 7z directory metadata" -Action {
  Assert-SafeSevenZipListing -Listing $conflictingDirectoryListing
}

$encryptedListing = $validListing.Replace(
  "Path = Chrome-bin\chrome.exe`r`nFolder = -`r`nEncrypted = -",
  "Path = Chrome-bin\chrome.exe`r`nFolder = -`r`nEncrypted = +"
).Replace(
  "Path = Chrome-bin\chrome.exe`nFolder = -`nEncrypted = -",
  "Path = Chrome-bin\chrome.exe`nFolder = -`nEncrypted = +"
)
Assert-Throws -Description "encrypted 7z entry" -Action {
  Assert-SafeSevenZipListing -Listing $encryptedListing
}
$childFirstListing = @"
7-Zip technical listing
----------
Path = Chrome-bin\parent\child.dll
Folder = -
Encrypted = -
Size = 1

Path = Chrome-bin\parent
Folder = -
Encrypted = -
Size = 1
"@
Assert-Throws -Description "child-first file-as-parent collision" -Action {
  Assert-SafeSevenZipListing -Listing $childFirstListing
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) `
  ("Kwiken-Runtime-Export-Test-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
  $insideRoot = Join-Path $temporaryRoot "inside"
  $insideChild = Join-Path $insideRoot "child"
  $outsideRoot = Join-Path $temporaryRoot "outside"
  New-Item -ItemType Directory -Path $insideChild -Force | Out-Null
  New-Item -ItemType Directory -Path $outsideRoot -Force | Out-Null
  Assert-PathOutsideRoot -Path $outsideRoot -Root $insideRoot `
    -Description "Synthetic outside path"
  Assert-Throws -Description "inside path rejection" -Action {
    Assert-PathOutsideRoot -Path $insideChild -Root $insideRoot `
      -Description "Synthetic inside path"
  }
  Assert-Throws -Description "device path rejection" -Action {
    Get-HandleResolvedPath -Path "\\?\$insideChild" | Out-Null
  }

  $privatePath = Join-Path $temporaryRoot "private"
  New-PrivateDirectory -Path $privatePath
  $expectedOwner = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $actualOwner = (Get-Acl -LiteralPath $privatePath).GetOwner(
    [Security.Principal.SecurityIdentifier]
  )
  if ($actualOwner -ne $expectedOwner) {
    throw "Private staging directory has the wrong owner."
  }
  $restrictedCodeSid = [Security.Principal.SecurityIdentifier]::new("S-1-5-12")
  $restrictedRules = @((Get-Acl -LiteralPath $privatePath).GetAccessRules(
      $true,
      $true,
      [Security.Principal.SecurityIdentifier]
    ) | Where-Object {
      $_.IdentityReference -eq $restrictedCodeSid -and
        $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow
    })
  if ($restrictedRules.Count -ne 1 -or
      ($restrictedRules[0].FileSystemRights -band
        [Security.AccessControl.FileSystemRights]::ReadAndExecute) -ne
        [Security.AccessControl.FileSystemRights]::ReadAndExecute -or
      ($restrictedRules[0].FileSystemRights -band
        [Security.AccessControl.FileSystemRights]::WriteData) -ne 0) {
    throw "Private staging does not grant Restricted Code read/execute-only access."
  }

  $publishParent = Join-Path $temporaryRoot "publish-parent"
  $privatePublication = Join-Path $privatePath "publication"
  $privatePublicationChild = Join-Path $privatePublication "child\payload.txt"
  New-Item -ItemType Directory -Path (Split-Path -Parent $privatePublicationChild) `
    -Force | Out-Null
  [IO.File]::WriteAllText($privatePublicationChild, "release")
  New-Item -ItemType Directory -Path $publishParent | Out-Null
  $publicationSddl = Set-PublicationAclForAtomicMove `
    -PublicationRoot $privatePublication -DestinationParent $publishParent
  $publishedPath = Join-Path $publishParent "release"
  [IO.Directory]::Move($privatePublication, $publishedPath)
  Assert-PublicationAclAfterAtomicMove -PublicationRoot $publishedPath `
    -ExpectedAccessSddl $publicationSddl
  if ((Get-Acl -LiteralPath $publishedPath).AreAccessRulesProtected -ne $true -or
      -not (Test-Path -LiteralPath (Join-Path $publishedPath "child\payload.txt"))) {
    throw "Atomic publication ACL preparation did not survive the move."
  }

  $guardedStaging = Join-Path $temporaryRoot `
    (".Kwiken-Runtime-Export-" + [Guid]::NewGuid().ToString("N") + ".staging")
  New-Item -ItemType Directory -Path $guardedStaging | Out-Null
  Remove-ExportStagingDirectory -Path $guardedStaging `
    -Parent ($temporaryRoot + [IO.Path]::DirectorySeparatorChar)
  if (Test-Path -LiteralPath $guardedStaging) {
    throw "Guarded staging cleanup did not remove its exact target."
  }

  $toolSource = Join-Path $temporaryRoot "tool-source"
  $toolSnapshot = Join-Path $privatePath "tool-snapshot"
  New-Item -ItemType Directory -Path (Join-Path $toolSource "Lib") -Force |
    Out-Null
  [IO.File]::WriteAllText(
    (Join-Path $toolSource "python3.exe"),
    "synthetic python",
    [Text.UTF8Encoding]::new($false)
  )
  [IO.File]::WriteAllText(
    (Join-Path $toolSource "Lib\module.py"),
    "value = 1",
    [Text.UTF8Encoding]::new($false)
  )
  $toolTreeHash = Copy-DirectorySnapshot -Source $toolSource `
    -Destination $toolSnapshot
  $toolExeHash = Get-LowerSha256 -Path (Join-Path $toolSnapshot "python3.exe")
  Assert-PythonSnapshot -PythonPath (Join-Path $toolSnapshot "python3.exe") `
    -RuntimeRoot $toolSnapshot -ExpectedExeSha256 $toolExeHash `
    -ExpectedRuntimeTreeSha256 $toolTreeHash
  [IO.File]::AppendAllText((Join-Path $toolSnapshot "Lib\module.py"), "`nchanged")
  Assert-Throws -Description "changed Python snapshot" -Action {
    Assert-PythonSnapshot -PythonPath (Join-Path $toolSnapshot "python3.exe") `
      -RuntimeRoot $toolSnapshot -ExpectedExeSha256 $toolExeHash `
      -ExpectedRuntimeTreeSha256 $toolTreeHash
  }

  $authenticatedPython = Join-Path $temporaryRoot "authenticated-python"
  $installedPython = Join-Path $temporaryRoot "installed-python"
  New-Item -ItemType Directory -Path (Join-Path $authenticatedPython "Lib") `
    -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $installedPython "Lib") `
    -Force | Out-Null
  foreach ($relativePath in @("python3.exe", "Lib\module.py")) {
    $authenticatedPath = Join-Path $authenticatedPython $relativePath
    $installedPath = Join-Path $installedPython $relativePath
    [IO.File]::WriteAllText(
      $authenticatedPath,
      "authenticated $relativePath",
      [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
      $installedPath,
      "authenticated $relativePath",
      [Text.UTF8Encoding]::new($false)
    )
  }
  $bytecodePath = Join-Path $installedPython `
    "Lib\__pycache__\module.cpython-311.pyc"
  New-Item -ItemType Directory -Path (Split-Path -Parent $bytecodePath) `
    -Force | Out-Null
  [IO.File]::WriteAllBytes($bytecodePath, [byte[]](1, 2, 3))
  Assert-InstalledPythonMatchesAuthenticatedRuntime `
    -InstalledRoot $installedPython -AuthenticatedRoot $authenticatedPython

  $unexpectedPythonFile = Join-Path $installedPython "Lib\injected.py"
  [IO.File]::WriteAllText($unexpectedPythonFile, "injected")
  Assert-Throws -Description "unauthenticated Python file" -Action {
    Assert-InstalledPythonMatchesAuthenticatedRuntime `
      -InstalledRoot $installedPython -AuthenticatedRoot $authenticatedPython
  }
  [IO.File]::Delete($unexpectedPythonFile)
  [IO.File]::AppendAllText((Join-Path $installedPython "Lib\module.py"), "changed")
  Assert-Throws -Description "changed authenticated Python file" -Action {
    Assert-InstalledPythonMatchesAuthenticatedRuntime `
      -InstalledRoot $installedPython -AuthenticatedRoot $authenticatedPython
  }

  $pePath = Join-Path $temporaryRoot "amd64.exe"
  $peBytes = [byte[]]::new(512)
  [BitConverter]::GetBytes([UInt16]0x5a4d).CopyTo($peBytes, 0)
  [BitConverter]::GetBytes([UInt32]0x80).CopyTo($peBytes, 0x3c)
  [BitConverter]::GetBytes([UInt32]0x00004550).CopyTo($peBytes, 0x80)
  [BitConverter]::GetBytes([UInt16]0x8664).CopyTo($peBytes, 0x84)
  [IO.File]::WriteAllBytes($pePath, $peBytes)
  if ((Get-PeMachine -Path $pePath) -ne 0x8664) {
    throw "AMD64 PE machine was not read correctly."
  }
  Assert-Amd64Pe -Path $pePath -Description "Synthetic AMD64 PE"

  [BitConverter]::GetBytes([UInt16]0x014c).CopyTo($peBytes, 0x84)
  [IO.File]::WriteAllBytes($pePath, $peBytes)
  Assert-Throws -Description "x86 PE rejection" -Action {
    Assert-Amd64Pe -Path $pePath -Description "Synthetic x86 PE"
  }
} finally {
  $leaf = Split-Path -Leaf $temporaryRoot
  if ($leaf -notmatch '^Kwiken-Runtime-Export-Test-[0-9a-f]{32}$') {
    throw "Refusing to remove unexpected test directory: $temporaryRoot"
  }
  Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
}

"runtime export helper tests passed"
