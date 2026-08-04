param(
  [string]$ChromiumRoot,
  [ValidateRange(1, 600)]
  [int]$ArchiveTimeoutSeconds = 120
)

$isDotSourced = $MyInvocation.InvocationName -eq "."

. (Join-Path $PSScriptRoot "common.ps1")

$script:KwikenAmd64Machine = [UInt16]0x8664
# Chromium's mini_installer target is built in the current/default x64
# toolchain for this fork. Keep its expected machine explicit rather than
# assuming every installer stub shares the runtime executable's architecture.
$script:KwikenInstallerStubMachine = [UInt16]0x8664
$script:KwikenMaximumStandardOutputBytes = 16 * 1024 * 1024
$script:KwikenMaximumStandardErrorBytes = 2 * 1024 * 1024

function Get-KwikenRequiredNonEmptyFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Name was not found at $Path."
  }

  $file = Get-Item -LiteralPath $Path
  if ($file.Length -le 0) {
    throw "$Name is empty at $Path."
  }
  if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "$Name cannot be a link or reparse point at $Path."
  }
  return $file
}

function Get-KwikenPeMachine {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  $file = Get-KwikenRequiredNonEmptyFile -Path $Path -Name $Name
  $stream = [IO.File]::Open(
    $file.FullName,
    [IO.FileMode]::Open,
    [IO.FileAccess]::Read,
    [IO.FileShare]::Read
  )
  $reader = [IO.BinaryReader]::new($stream)
  try {
    if ($stream.Length -lt 70 -or $reader.ReadUInt16() -ne 0x5a4d) {
      throw "$Name is not a valid PE image at $Path."
    }
    $stream.Position = 0x3c
    $headerOffset = $reader.ReadUInt32()
    if ($headerOffset -gt ($stream.Length - 6)) {
      throw "$Name has a PE header outside the file at $Path."
    }
    $stream.Position = $headerOffset
    if ($reader.ReadUInt32() -ne 0x00004550) {
      throw "$Name has an invalid PE signature at $Path."
    }
    return $reader.ReadUInt16()
  } finally {
    $reader.Dispose()
    $stream.Dispose()
  }
}

function Get-KwikenLowerSha256 {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  Get-KwikenRequiredNonEmptyFile -Path $Path -Name $Name | Out-Null
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-KwikenPeArtifact {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedProductName,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedVersion,
    [Parameter(Mandatory = $true)]
    [UInt16]$ExpectedMachine,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedMachineName
  )

  $file = Get-KwikenRequiredNonEmptyFile -Path $Path -Name $Name
  $machine = Get-KwikenPeMachine -Path $file.FullName -Name $Name
  if ($machine -ne $ExpectedMachine) {
    throw "$Name has PE machine 0x$($machine.ToString('x4')); expected $ExpectedMachineName (0x$($ExpectedMachine.ToString('x4')))."
  }
  $versionInfo = $file.VersionInfo
  $numericFileVersion = "{0}.{1}.{2}.{3}" -f @(
    $versionInfo.FileMajorPart,
    $versionInfo.FileMinorPart,
    $versionInfo.FileBuildPart,
    $versionInfo.FilePrivatePart
  )

  if (-not [string]::Equals(
      $versionInfo.ProductName,
      $ExpectedProductName,
      [StringComparison]::Ordinal
    )) {
    throw "$Name has ProductName '$($versionInfo.ProductName)', expected '$ExpectedProductName'."
  }
  if ($numericFileVersion -ne $ExpectedVersion) {
    throw "$Name has FileVersion '$numericFileVersion', expected '$ExpectedVersion'."
  }

  return [pscustomobject]@{
    Name = $Name
    Path = $file.FullName
    Bytes = $file.Length
    ProductName = $versionInfo.ProductName
    FileVersion = $numericFileVersion
    Machine = $machine
    Sha256 = Get-KwikenLowerSha256 -Path $file.FullName -Name $Name
  }
}

function Assert-KwikenMatchingFileHash {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ExpectedPath,
    [Parameter(Mandatory = $true)]
    [string]$ActualPath,
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  $expectedHash = Get-KwikenLowerSha256 -Path $ExpectedPath `
    -Name "Native output $Name"
  $actualHash = Get-KwikenLowerSha256 -Path $ActualPath `
    -Name "Archived $Name"
  if ($actualHash -ne $expectedHash) {
    throw "Archived $Name does not match the corresponding native output (expected $expectedHash, found $actualHash)."
  }
  return $actualHash
}

function ConvertTo-KwikenWindowsCommandLineArgument {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Argument
  )

  if ($Argument.IndexOf([char]0) -ge 0) {
    throw "Process arguments cannot contain a null character."
  }
  if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
    return $Argument
  }

  $builder = [Text.StringBuilder]::new()
  [void]$builder.Append([char]34)
  $backslashes = 0
  foreach ($character in $Argument.ToCharArray()) {
    if ($character -eq [char]92) {
      $backslashes++
      continue
    }
    if ($character -eq [char]34) {
      [void]$builder.Append([string]::new([char]92, (2 * $backslashes) + 1))
      [void]$builder.Append([char]34)
      $backslashes = 0
      continue
    }
    if ($backslashes -gt 0) {
      [void]$builder.Append([string]::new([char]92, $backslashes))
      $backslashes = 0
    }
    [void]$builder.Append($character)
  }
  if ($backslashes -gt 0) {
    [void]$builder.Append([string]::new([char]92, 2 * $backslashes))
  }
  [void]$builder.Append([char]34)
  return $builder.ToString()
}

function Join-KwikenWindowsCommandLineArguments {
  param(
    [AllowEmptyCollection()]
    [string[]]$Arguments = @()
  )

  $quoted = foreach ($argument in $Arguments) {
    if ($null -eq $argument) {
      throw "Process arguments cannot be null."
    }
    ConvertTo-KwikenWindowsCommandLineArgument -Argument $argument
  }
  return ($quoted -join " ")
}

function ConvertFrom-KwikenSevenZipTechnicalListing {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [AllowEmptyString()]
    [string[]]$Lines
  )

  $readingEntries = $false
  $fields = @{}
  foreach ($line in $Lines) {
    if ($line -match '^-{5,}\s*$') {
      $readingEntries = $true
      $fields = @{}
      continue
    }
    if (-not $readingEntries) {
      continue
    }
    if ([string]::IsNullOrEmpty($line)) {
      if ($fields.Count -gt 0) {
        ConvertTo-KwikenSevenZipEntry -Fields $fields
        $fields = @{}
      }
      continue
    }
    if ($line -match '^([^=]+?) = (.*)$') {
      $fields[$Matches[1].Trim()] = $Matches[2]
    }
  }
  if ($fields.Count -gt 0) {
    ConvertTo-KwikenSevenZipEntry -Fields $fields
  }
}

function ConvertTo-KwikenSevenZipEntry {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Fields
  )

  if (-not $Fields.ContainsKey("Path")) {
    throw "7za returned an archive entry without a path."
  }

  $size = $null
  if ($Fields.ContainsKey("Size")) {
    [long]$parsedSize = 0
    if (-not [long]::TryParse(
        [string]$Fields["Size"],
        [Globalization.NumberStyles]::Integer,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$parsedSize
      ) -or $parsedSize -lt 0) {
      throw "7za returned an invalid size for '$($Fields['Path'])'."
    }
    $size = $parsedSize
  }

  $attributes = if ($Fields.ContainsKey("Attributes")) {
    [string]$Fields["Attributes"]
  } else {
    ""
  }
  $folder = if ($Fields.ContainsKey("Folder")) {
    [string]$Fields["Folder"]
  } else {
    ""
  }
  $linkOrReparseFields = @($Fields.Keys | Where-Object {
    $_ -match '(?i)(?:symbolic\s*link|sym\s*link|hard\s*link|reparse|junction|^link$)'
  } | ForEach-Object {
    [pscustomobject]@{
      Name = [string]$_
      Value = [string]$Fields[$_]
    }
  })
  $activeLinkOrReparseFields = @($linkOrReparseFields | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_.Value) -and $_.Value -ne "-"
  })
  $hasLinkLikeAttributes =
    $attributes -match '(?i)(?:^|\s)l[rwx-]{9}(?:\s|$)' -or
    $attributes -match '(?i)(reparse|junction|symbolic\s+link)'

  return [pscustomobject]@{
    Path = [string]$Fields["Path"]
    Size = $size
    Attributes = $attributes
    Encrypted = $(if ($Fields.ContainsKey("Encrypted")) {
        [string]$Fields["Encrypted"]
      } else {
        ""
      })
    IsFolder = $folder -eq "+" -or $attributes -match "D"
    LinkOrReparseFields = $linkOrReparseFields
    HasLinkOrReparseMetadata =
      $activeLinkOrReparseFields.Count -gt 0 -or $hasLinkLikeAttributes
  }
}

function Initialize-KwikenValidationCaptureInterop {
  if ("KwikenValidationBoundedCapture" -as [type]) {
    return
  }
  Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public sealed class KwikenValidationBoundedCapture {
    private readonly Stream input;
    private readonly int maximumBytes;
    private readonly MemoryStream content = new MemoryStream();
    private volatile bool limitExceeded;
    private Exception failure;

    private KwikenValidationBoundedCapture(Stream input, int maximumBytes) {
        if (input == null) throw new ArgumentNullException("input");
        if (maximumBytes < 1) throw new ArgumentOutOfRangeException("maximumBytes");
        this.input = input;
        this.maximumBytes = maximumBytes;
        Completion = Task.Factory.StartNew(
            Capture,
            CancellationToken.None,
            TaskCreationOptions.LongRunning,
            TaskScheduler.Default);
    }

    public Task Completion { get; private set; }
    public bool LimitExceeded { get { return limitExceeded; } }

    public static KwikenValidationBoundedCapture Start(
            Stream input, int maximumBytes) {
        return new KwikenValidationBoundedCapture(input, maximumBytes);
    }

    private void Capture() {
        byte[] buffer = new byte[8192];
        try {
            while (true) {
                int count = input.Read(buffer, 0, buffer.Length);
                if (count == 0) return;
                if (content.Length + count > maximumBytes) {
                    limitExceeded = true;
                    return;
                }
                content.Write(buffer, 0, count);
            }
        } catch (Exception exception) {
            failure = exception;
        }
    }

    public string GetUtf8Text() {
        if (!Completion.IsCompleted) {
            throw new InvalidOperationException("Capture has not completed.");
        }
        if (failure != null) {
            throw new IOException("Could not read redirected process output.", failure);
        }
        if (limitExceeded) {
            throw new InvalidOperationException(
                "Redirected process output exceeded its byte limit.");
        }
        return new UTF8Encoding(false, false).GetString(content.ToArray());
    }
}
"@
}

function Stop-KwikenValidationProcessChecked {
  param(
    [Parameter(Mandatory = $true)]
    [Diagnostics.Process]$Process
  )

  $Process.Refresh()
  if ($Process.HasExited) {
    return
  }
  $processId = $Process.Id
  $Process.Kill()
  if (-not $Process.WaitForExit(5000)) {
    throw "Process $processId did not terminate after Kill()."
  }
  $Process.Refresh()
  if (-not $Process.HasExited) {
    throw "Process $processId did not report an exited state after Kill()."
  }
}

function Invoke-KwikenBoundedProcess {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [Parameter(Mandatory = $true)]
    [string]$Arguments,
    [Parameter(Mandatory = $true)]
    [string]$WorkingDirectory,
    [ValidateRange(1, 600)]
    [int]$TimeoutSeconds,
    [ValidateRange(1, 268435456)]
    [int]$MaximumStandardOutputBytes = $script:KwikenMaximumStandardOutputBytes,
    [ValidateRange(1, 268435456)]
    [int]$MaximumStandardErrorBytes = $script:KwikenMaximumStandardErrorBytes
  )

  $startInfo = New-Object Diagnostics.ProcessStartInfo
  $startInfo.FileName = $FilePath
  $startInfo.Arguments = $Arguments
  $startInfo.WorkingDirectory = $WorkingDirectory
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true

  $process = New-Object Diagnostics.Process
  $process.StartInfo = $startInfo
  $started = $false
  $outputCapture = $null
  $errorCapture = $null
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  try {
    Initialize-KwikenValidationCaptureInterop
    if (-not $process.Start()) {
      throw "Could not start $FilePath."
    }
    $started = $true
    $processId = $process.Id
    $process.StandardInput.Close()
    $outputCapture = [KwikenValidationBoundedCapture]::Start(
      $process.StandardOutput.BaseStream,
      $MaximumStandardOutputBytes
    )
    $errorCapture = [KwikenValidationBoundedCapture]::Start(
      $process.StandardError.BaseStream,
      $MaximumStandardErrorBytes
    )

    $limitDescription = $null
    while (-not $process.HasExited) {
      if ($outputCapture.LimitExceeded) {
        $limitDescription = "standard output"
        break
      }
      if ($errorCapture.LimitExceeded) {
        $limitDescription = "standard error"
        break
      }
      $remainingMilliseconds = [int][Math]::Floor(
        ($deadline - [DateTime]::UtcNow).TotalMilliseconds
      )
      if ($remainingMilliseconds -le 0) {
        break
      }
      [void]$process.WaitForExit([Math]::Min(100, $remainingMilliseconds))
      $process.Refresh()
    }

    if ($null -ne $limitDescription) {
      Stop-KwikenValidationProcessChecked -Process $process
      throw "Process $processId exceeded its $limitDescription capture limit and was terminated."
    }
    if (-not $process.HasExited) {
      Stop-KwikenValidationProcessChecked -Process $process
      throw "Process $processId timed out after $TimeoutSeconds seconds and was terminated."
    }
    foreach ($capture in @($outputCapture, $errorCapture)) {
      $remainingMilliseconds = [Math]::Max(
        1,
        [int][Math]::Floor(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
      )
      if (-not $capture.Completion.Wait($remainingMilliseconds)) {
        throw "Process $processId did not close redirected output before its deadline."
      }
    }
    return [pscustomobject]@{
      ProcessId = $processId
      ExitCode = $process.ExitCode
      StandardOutput = $outputCapture.GetUtf8Text()
      StandardError = $errorCapture.GetUtf8Text()
    }
  } finally {
    if ($started -and -not $process.HasExited) {
      Stop-KwikenValidationProcessChecked -Process $process
    }
    $process.Dispose()
  }
}

function Invoke-KwikenSevenZip {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("l", "t")]
    [string]$Command,
    [Parameter(Mandatory = $true)]
    [string]$SevenZipPath,
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,
    [ValidateRange(1, 600)]
    [int]$TimeoutSeconds
  )

  Get-KwikenRequiredNonEmptyFile -Path $SevenZipPath -Name "Chromium's pinned 7za" | Out-Null
  Get-KwikenRequiredNonEmptyFile -Path $ArchivePath -Name "chrome.7z" | Out-Null

  $argumentValues = [Collections.Generic.List[string]]::new()
  $argumentValues.Add($Command)
  if ($Command -eq "l") {
    $argumentValues.Add("-slt")
  }
  foreach ($argument in @(
      "-sccUTF-8", "-p-", "-bd", "-bb0", "-bso1", "-bse2", "-bsp0",
      "--", $ArchivePath
    )) {
    $argumentValues.Add($argument)
  }
  $arguments = Join-KwikenWindowsCommandLineArguments `
    -Arguments $argumentValues.ToArray()
  return Invoke-KwikenBoundedProcess -FilePath $SevenZipPath `
    -Arguments $arguments -WorkingDirectory (Split-Path -Parent $ArchivePath) `
    -TimeoutSeconds $TimeoutSeconds
}

function Get-KwikenSevenZipDiagnostic {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Result
  )

  $diagnostic = "$($Result.StandardError)`n$($Result.StandardOutput)".Trim()
  if ($diagnostic.Length -gt 1200) {
    return $diagnostic.Substring($diagnostic.Length - 1200)
  }
  return $diagnostic
}

function Get-KwikenSevenZipEntries {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SevenZipPath,
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,
    [ValidateRange(1, 600)]
    [int]$TimeoutSeconds
  )

  $result = Invoke-KwikenSevenZip -Command "l" -SevenZipPath $SevenZipPath `
    -ArchivePath $ArchivePath -TimeoutSeconds $TimeoutSeconds
  if ($result.ExitCode -ne 0) {
    $diagnostic = Get-KwikenSevenZipDiagnostic -Result $result
    throw "Chromium's pinned 7za could not inspect chrome.7z (exit $($result.ExitCode)): $diagnostic"
  }
  $entries = @(ConvertFrom-KwikenSevenZipTechnicalListing -Lines @(
      $result.StandardOutput -split "`r?`n"
    ))
  if ($entries.Count -eq 0) {
    throw "chrome.7z did not contain any archive entries."
  }
  return $entries
}

function Test-KwikenSevenZipArchive {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SevenZipPath,
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,
    [ValidateRange(1, 600)]
    [int]$TimeoutSeconds
  )

  $result = Invoke-KwikenSevenZip -Command "t" -SevenZipPath $SevenZipPath `
    -ArchivePath $ArchivePath -TimeoutSeconds $TimeoutSeconds
  if ($result.ExitCode -ne 0) {
    $diagnostic = Get-KwikenSevenZipDiagnostic -Result $result
    throw "chrome.7z failed its bounded 7za integrity test (exit $($result.ExitCode)): $diagnostic"
  }
}

function Test-KwikenReservedWindowsDeviceName {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  if (@('CON', 'PRN', 'AUX', 'NUL', 'CONIN$', 'CONOUT$') -contains $Name) {
    return $true
  }
  if ($Name -match '^(?i:COM|LPT)[1-9]$') {
    return $true
  }
  if ($Name.Length -eq 4 -and
      ($Name.StartsWith("COM", [StringComparison]::OrdinalIgnoreCase) -or
       $Name.StartsWith("LPT", [StringComparison]::OrdinalIgnoreCase)) -and
      @([int]0x00B9, [int]0x00B2, [int]0x00B3) -contains [int]$Name[3]) {
    return $true
  }
  return $false
}

function Assert-KwikenSafeArchiveEntries {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Entries
  )

  $seenPaths = New-Object 'Collections.Generic.HashSet[string]' `
    ([StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in $Entries) {
    $path = [string]$entry.Path
    if ([string]::IsNullOrEmpty($path)) {
      throw "chrome.7z contains an empty entry path."
    }
    if ($path.IndexOf(':') -ge 0) {
      throw "chrome.7z contains a drive-qualified, colon, or ADS path: $path"
    }
    if ($path -match '[\x00-\x1F]') {
      throw "chrome.7z contains a control character in entry path: $path"
    }
    if ($path -match '[<>"|?*]') {
      throw "chrome.7z contains a Windows-forbidden character in entry path: $path"
    }
    if ($path.StartsWith("\") -or $path.StartsWith("/") -or
        [IO.Path]::IsPathRooted($path)) {
      throw "chrome.7z contains a rooted entry path: $path"
    }

    $segments = $path.Split(
      [char[]]@([char]92, [char]47),
      [StringSplitOptions]::None
    )
    if (@($segments | Where-Object { $_.Length -eq 0 }).Count -gt 0) {
      throw "chrome.7z contains a path with an empty segment: $path"
    }
    if (@($segments | Where-Object { $_ -eq "." -or $_ -eq ".." }).Count -gt 0) {
      throw "chrome.7z contains a traversal entry path: $path"
    }
    foreach ($segment in $segments) {
      if ($segment -match '[\x00-\x1F]') {
        throw "chrome.7z contains a control character in entry path: $path"
      }
      if ($segment -match '[<>"|?*]') {
        throw "chrome.7z contains a Windows-forbidden character in entry path: $path"
      }
      if ($segment -match '[ .]$') {
        throw "chrome.7z contains an entry segment ending in a dot or space: $path"
      }

      $dotIndex = $segment.IndexOf('.')
      $deviceStem = if ($dotIndex -ge 0) {
        $segment.Substring(0, $dotIndex).TrimEnd([char[]]@([char]32, [char]46))
      } else {
        $segment
      }
      if (Test-KwikenReservedWindowsDeviceName -Name $deviceStem) {
        throw "chrome.7z contains a reserved Windows device name in entry path: $path"
      }
    }

    $normalizedPath = $segments -join "\"
    if (-not $seenPaths.Add($normalizedPath)) {
      throw "chrome.7z contains a case-insensitive duplicate entry path: $path"
    }
    if ($entry.HasLinkOrReparseMetadata) {
      $metadata = @($entry.LinkOrReparseFields | ForEach-Object {
        "$($_.Name)=$($_.Value)"
      }) -join ", "
      if ([string]::IsNullOrWhiteSpace($metadata)) {
        $metadata = "link-like attributes '$($entry.Attributes)'"
      }
      throw "chrome.7z contains a symbolic link, hard link, or reparse-like entry at ${path}: $metadata"
    }
    if (-not $entry.IsFolder) {
      if ($null -eq $entry.Size -or $entry.Size -lt 0) {
        throw "Non-directory chrome.7z entry $path has no valid nonnegative size."
      }
      if ($entry.Encrypted -ne "-") {
        throw "Non-directory chrome.7z entry $path is encrypted or has no encryption status."
      }
    }
    [pscustomobject]@{
      Path = $normalizedPath
      Size = $entry.Size
      Attributes = $entry.Attributes
      Encrypted = $entry.Encrypted
      IsFolder = $entry.IsFolder
      LinkOrReparseFields = $entry.LinkOrReparseFields
      HasLinkOrReparseMetadata = $entry.HasLinkOrReparseMetadata
    }
  }
}

function Assert-KwikenChromeArchiveLayout {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Entries,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedVersion
  )

  $safeEntries = @(Assert-KwikenSafeArchiveEntries -Entries $Entries)
  $unexpectedRootEntries = @($safeEntries | Where-Object {
    -not $_.Path.Equals("Chrome-bin", [StringComparison]::OrdinalIgnoreCase) -and
    -not $_.Path.StartsWith("Chrome-bin\", [StringComparison]::OrdinalIgnoreCase)
  })
  if ($unexpectedRootEntries.Count -gt 0) {
    throw "chrome.7z contains entries outside Chrome-bin: $($unexpectedRootEntries[0].Path)"
  }

  $requiredEntries = @(
    "Chrome-bin\chrome.exe",
    "Chrome-bin\chrome_proxy.exe",
    "Chrome-bin\$ExpectedVersion\chrome.dll",
    "Chrome-bin\$ExpectedVersion\resources.pak",
    "Chrome-bin\$ExpectedVersion\Locales\en-US.pak"
  )
  foreach ($requiredEntry in $requiredEntries) {
    $matchingEntry = $safeEntries | Where-Object {
      $_.Path.Equals($requiredEntry, [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1
    if (-not $matchingEntry) {
      throw "chrome.7z is missing required entry $requiredEntry."
    }
    if ($matchingEntry.IsFolder) {
      throw "Required chrome.7z entry $requiredEntry is a directory, not a regular file."
    }
    if ($null -eq $matchingEntry.Size -or $matchingEntry.Size -le 0) {
      throw "Required chrome.7z entry $requiredEntry is empty or has no valid size."
    }
    if ($matchingEntry.Encrypted -ne "-") {
      throw "Required chrome.7z entry $requiredEntry is encrypted or has no encryption status."
    }
  }

  $otherVersionEntries = @($safeEntries | Where-Object {
    if ($_.Path -match '^Chrome-bin\\(\d+\.\d+\.\d+\.\d+)\\') {
      return $Matches[1] -ne $ExpectedVersion
    }
    return $false
  })
  if ($otherVersionEntries.Count -gt 0) {
    throw "chrome.7z contains an unexpected version directory: $($otherVersionEntries[0].Path)"
  }

  return [pscustomobject]@{
    Root = "Chrome-bin"
    VersionDirectory = "Chrome-bin\$ExpectedVersion"
    EntryCount = $safeEntries.Count
  }
}

function Assert-KwikenNoReparseAncestors {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $current = [IO.Path]::GetFullPath($Path)
  while ($true) {
    $item = $null
    try {
      $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
    } catch [Management.Automation.ItemNotFoundException] {
      $item = $null
    }
    if ($null -ne $item -and
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Native validation paths cannot traverse a link or reparse point: $current"
    }
    $parent = Split-Path -Parent $current
    if (-not $parent -or $parent -eq $current) {
      break
    }
    $current = $parent
  }
}

function Assert-KwikenNoReparseTree {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  Assert-KwikenNoReparseAncestors -Path $Path
  $root = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  $items = @($root) + @(Get-ChildItem -LiteralPath $root.FullName -Force -Recurse)
  foreach ($item in $items) {
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Native validation data cannot contain a link or reparse point: $($item.FullName)"
    }
  }
}

function Initialize-KwikenPrivateValidationDirectoryInterop {
  if ("KwikenPrivateValidationDirectory" -as [type]) {
    return
  }
  Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class KwikenPrivateValidationDirectory {
    [StructLayout(LayoutKind.Sequential)]
    private struct SECURITY_ATTRIBUTES {
        public Int32 nLength;
        public IntPtr lpSecurityDescriptor;
        public Int32 bInheritHandle;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(
        string descriptor,
        UInt32 revision,
        out IntPtr securityDescriptor,
        out UInt32 securityDescriptorSize);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateDirectory(
        string path,
        ref SECURITY_ATTRIBUTES securityAttributes);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr memory);

    public static void Create(string path, string sddl) {
        IntPtr descriptor;
        UInt32 descriptorSize;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptor(
                sddl, 1, out descriptor, out descriptorSize)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        try {
            var attributes = new SECURITY_ATTRIBUTES();
            attributes.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
            attributes.lpSecurityDescriptor = descriptor;
            attributes.bInheritHandle = 0;
            if (!CreateDirectory(path, ref attributes)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        } finally {
            LocalFree(descriptor);
        }
    }
}
"@
}

function New-KwikenPrivateValidationDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Parent
  )

  $fullParent = [IO.Path]::GetFullPath($Parent)
  Assert-KwikenNoReparseAncestors -Path $fullParent
  $parentItem = Get-Item -LiteralPath $fullParent -Force -ErrorAction Stop
  if (-not $parentItem.PSIsContainer) {
    throw "Native validation temporary parent is not a directory: $fullParent"
  }
  $path = Join-Path $fullParent `
    ("Kwiken-Native-Validation-" + [Guid]::NewGuid().ToString("N") + ".staging")
  $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $sddl = "O:{0}G:{0}D:P(A;OICI;FA;;;{0})(A;OICI;FA;;;SY)" -f `
    $currentSid.Value
  $created = $false
  try {
    Initialize-KwikenPrivateValidationDirectoryInterop
    [KwikenPrivateValidationDirectory]::Create($path, $sddl)
    $created = $true
    $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
    $actualOwner = $acl.GetOwner([Security.Principal.SecurityIdentifier])
    if ($actualOwner -ne $currentSid -or -not $acl.AreAccessRulesProtected) {
      throw "Private native-validation ACL could not be established for $path."
    }
  } catch {
    $creationFailure = $_
    if ($created -and (Test-Path -LiteralPath $path -PathType Container)) {
      try {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
      } catch {
        throw "Private native-validation setup failed and cleanup also failed. Setup: $($creationFailure.Exception.Message) Cleanup: $($_.Exception.Message)"
      }
    }
    throw $creationFailure
  }
  return $path
}

function Remove-KwikenPrivateValidationDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Parent
  )

  $fullPath = [IO.Path]::GetFullPath($Path)
  $fullParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
  $actualParent = [IO.Path]::GetFullPath((Split-Path -Parent $fullPath)).TrimEnd('\')
  $leaf = Split-Path -Leaf $fullPath
  if (-not $actualParent.Equals($fullParent, [StringComparison]::OrdinalIgnoreCase) -or
      $leaf -notmatch '^Kwiken-Native-Validation-[0-9a-f]{32}\.staging$') {
    throw "Refusing to remove an unexpected native-validation directory: $fullPath"
  }
  if (Test-Path -LiteralPath $fullPath) {
    Assert-KwikenNoReparseTree -Path $fullPath
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) {
      throw "Refusing to recursively remove a non-directory validation path: $fullPath"
    }
    Remove-Item -LiteralPath $fullPath -Recurse -Force -ErrorAction Stop
  }
}

function Copy-KwikenValidationSnapshot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [Parameter(Mandatory = $true)]
    [string]$Destination,
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  $sourceFile = Get-KwikenRequiredNonEmptyFile -Path $Source -Name $Name
  Assert-KwikenNoReparseAncestors -Path $sourceFile.FullName
  if (Test-Path -LiteralPath $Destination) {
    throw "Native validation snapshot destination already exists: $Destination"
  }
  $sourceStream = [IO.File]::Open(
    $sourceFile.FullName,
    [IO.FileMode]::Open,
    [IO.FileAccess]::Read,
    [IO.FileShare]::Read
  )
  $destinationStream = $null
  try {
    $expectedLength = $sourceStream.Length
    $destinationStream = [IO.File]::Open(
      $Destination,
      [IO.FileMode]::CreateNew,
      [IO.FileAccess]::Write,
      [IO.FileShare]::None
    )
    $sourceStream.CopyTo($destinationStream)
    $destinationStream.Flush($true)
    if ($sourceStream.Length -ne $expectedLength -or
        $sourceStream.Position -ne $expectedLength) {
      throw "$Name changed while its private validation snapshot was created."
    }
  } finally {
    if ($null -ne $destinationStream) {
      $destinationStream.Dispose()
    }
    $sourceStream.Dispose()
  }
  return Get-Item -LiteralPath $Destination -Force -ErrorAction Stop
}

function Expand-KwikenValidatedCriticalArchiveFiles {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SevenZipPath,
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,
    [Parameter(Mandatory = $true)]
    [object[]]$Entries,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedVersion,
    [Parameter(Mandatory = $true)]
    [string]$Destination,
    [Parameter(Mandatory = $true)]
    [hashtable]$ExpectedSizes,
    [ValidateRange(1, 600)]
    [int]$TimeoutSeconds
  )

  # Re-run the complete path, link, encryption, size, and layout validation in
  # this extraction boundary so no caller can extract before approving every
  # archive entry returned by the bounded technical listing.
  $layout = Assert-KwikenChromeArchiveLayout -Entries $Entries `
    -ExpectedVersion $ExpectedVersion
  $expectedPaths = @(
    "Chrome-bin\chrome.exe",
    "Chrome-bin\chrome_proxy.exe",
    "Chrome-bin\$ExpectedVersion\chrome.dll"
  )
  $archivePaths = [Collections.Generic.List[string]]::new()
  $listedSizes = [Collections.Generic.Dictionary[string,Int64]]::new(
    [StringComparer]::OrdinalIgnoreCase
  )
  foreach ($expectedPath in $expectedPaths) {
    $entry = $Entries | Where-Object {
      ([string]$_.Path).Replace('/', '\').Equals(
        $expectedPath,
        [StringComparison]::OrdinalIgnoreCase
      )
    } | Select-Object -First 1
    if (-not $entry) {
      throw "Validated archive entry disappeared before extraction: $expectedPath"
    }
    if (-not $ExpectedSizes.ContainsKey($expectedPath)) {
      throw "Native output size expectation is missing for $expectedPath."
    }
    if ([Int64]$entry.Size -ne [Int64]$ExpectedSizes[$expectedPath]) {
      throw "Archived $expectedPath has $($entry.Size) bytes; corresponding native output has $($ExpectedSizes[$expectedPath])."
    }
    $archivePaths.Add([string]$entry.Path)
    $listedSizes[$expectedPath] = [Int64]$entry.Size
  }

  if (Test-Path -LiteralPath $Destination) {
    throw "Native validation extraction destination already exists: $Destination"
  }
  New-Item -ItemType Directory -Path $Destination -ErrorAction Stop | Out-Null
  $arguments = [Collections.Generic.List[string]]::new()
  foreach ($argument in @(
      "x", "-y", "-aoa", "-sccUTF-8", "-p-", "-bd", "-bb0", "-bso1",
      "-bse2", "-bsp0", "-o$Destination", "--", $ArchivePath
    )) {
    $arguments.Add($argument)
  }
  foreach ($archivePath in $archivePaths) {
    $arguments.Add($archivePath)
  }
  $result = Invoke-KwikenBoundedProcess -FilePath $SevenZipPath `
    -Arguments (Join-KwikenWindowsCommandLineArguments -Arguments $arguments.ToArray()) `
    -WorkingDirectory (Split-Path -Parent $ArchivePath) `
    -TimeoutSeconds $TimeoutSeconds
  if ($result.ExitCode -ne 0) {
    $diagnostic = Get-KwikenSevenZipDiagnostic -Result $result
    throw "Chromium's pinned 7za could not extract validated critical files (exit $($result.ExitCode)): $diagnostic"
  }

  Assert-KwikenNoReparseTree -Path $Destination
  $extractedFiles = @(Get-ChildItem -LiteralPath $Destination -File -Force -Recurse)
  if ($extractedFiles.Count -ne $expectedPaths.Count) {
    throw "Critical archive extraction produced $($extractedFiles.Count) files; expected $($expectedPaths.Count)."
  }
  $fullDestination = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
  $seen = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
  )
  foreach ($file in $extractedFiles) {
    $relativePath = $file.FullName.Substring($fullDestination.Length + 1)
    if (-not $listedSizes.ContainsKey($relativePath)) {
      throw "Critical archive extraction produced an unexpected file: $relativePath"
    }
    if (-not $seen.Add($relativePath)) {
      throw "Critical archive extraction produced a duplicate file: $relativePath"
    }
    if ($file.Length -ne $listedSizes[$relativePath]) {
      throw "Extracted $relativePath has $($file.Length) bytes; listing declared $($listedSizes[$relativePath])."
    }
  }
  foreach ($expectedPath in $expectedPaths) {
    if (-not $seen.Contains($expectedPath)) {
      throw "Critical archive extraction is missing $expectedPath."
    }
  }

  return [pscustomobject]@{
    Layout = $layout
    Root = Join-Path $Destination "Chrome-bin"
    ChromePath = Join-Path $Destination "Chrome-bin\chrome.exe"
    ChromeProxyPath = Join-Path $Destination "Chrome-bin\chrome_proxy.exe"
    ChromeDllPath = Join-Path $Destination `
      "Chrome-bin\$ExpectedVersion\chrome.dll"
  }
}

function Invoke-KwikenNativeBuildValidation {
  param(
    [string]$ChromiumRoot,
    [ValidateRange(1, 600)]
    [int]$ArchiveTimeoutSeconds = 120
  )

  $resolvedChromiumRoot = Resolve-KwikenBuildRoot -Value $ChromiumRoot `
    -DefaultValue (Get-DefaultChromiumRoot) -Name "ChromiumRoot"
  $environmentSnapshot = New-ChromiumBuildEnvironmentSnapshot
  try {
    Set-ChromiumGitEnvironment
    $sourceRoot = Assert-ChromiumCheckout -ChromiumRoot $resolvedChromiumRoot
    $sourceDeltaHash = Assert-KwikenSourceDelta -SourceRoot $sourceRoot
    $outputRoot = Join-Path $sourceRoot "out\Kwiken"
    $sevenZipPath = Join-Path $sourceRoot `
      "third_party\lzma_sdk\bin\host_platform\7za.exe"
    Get-KwikenRequiredNonEmptyFile -Path $sevenZipPath `
      -Name "Chromium's pinned 7za" | Out-Null
    Assert-KwikenNoReparseAncestors -Path $sevenZipPath

    $temporaryParent = [IO.Path]::GetTempPath()
    $temporaryRoot = $null
    $validationFailure = $null
    $cleanupFailure = $null
    $validationResult = $null
    try {
      $temporaryRoot = New-KwikenPrivateValidationDirectory `
        -Parent $temporaryParent
      $snapshotRoot = Join-Path $temporaryRoot "snapshots"
      New-Item -ItemType Directory -Path $snapshotRoot -ErrorAction Stop | Out-Null
      $snapshotChrome = Join-Path $snapshotRoot "chrome.exe"
      $snapshotChromeProxy = Join-Path $snapshotRoot "chrome_proxy.exe"
      $snapshotChromeDll = Join-Path $snapshotRoot "chrome.dll"
      $snapshotMiniInstaller = Join-Path $snapshotRoot "mini_installer.exe"
      $snapshotArchive = Join-Path $snapshotRoot "chrome.7z"

      [void](Copy-KwikenValidationSnapshot `
          -Source (Join-Path $outputRoot "chrome.exe") `
          -Destination $snapshotChrome -Name "chrome.exe")
      [void](Copy-KwikenValidationSnapshot `
          -Source (Join-Path $outputRoot "chrome_proxy.exe") `
          -Destination $snapshotChromeProxy -Name "chrome_proxy.exe")
      [void](Copy-KwikenValidationSnapshot `
          -Source (Join-Path $outputRoot "chrome.dll") `
          -Destination $snapshotChromeDll -Name "chrome.dll")
      [void](Copy-KwikenValidationSnapshot `
          -Source (Join-Path $outputRoot "mini_installer.exe") `
          -Destination $snapshotMiniInstaller -Name "mini_installer.exe")
      $archive = Copy-KwikenValidationSnapshot `
        -Source (Join-Path $outputRoot "chrome.7z") `
        -Destination $snapshotArchive -Name "chrome.7z"

      $chrome = Get-KwikenPeArtifact -Path $snapshotChrome `
        -Name "chrome.exe" -ExpectedProductName "Kwiken" `
        -ExpectedVersion $script:Version `
        -ExpectedMachine $script:KwikenAmd64Machine `
        -ExpectedMachineName "AMD64"
      $chromeProxy = Get-KwikenPeArtifact -Path $snapshotChromeProxy `
        -Name "chrome_proxy.exe" -ExpectedProductName "Kwiken" `
        -ExpectedVersion $script:Version `
        -ExpectedMachine $script:KwikenAmd64Machine `
        -ExpectedMachineName "AMD64"
      $chromeDll = Get-KwikenPeArtifact -Path $snapshotChromeDll `
        -Name "chrome.dll" -ExpectedProductName "Kwiken" `
        -ExpectedVersion $script:Version `
        -ExpectedMachine $script:KwikenAmd64Machine `
        -ExpectedMachineName "AMD64"
      $miniInstaller = Get-KwikenPeArtifact -Path $snapshotMiniInstaller `
        -Name "mini_installer.exe" -ExpectedProductName "Kwiken Installer" `
        -ExpectedVersion $script:Version `
        -ExpectedMachine $script:KwikenInstallerStubMachine `
        -ExpectedMachineName "Chromium x64 installer stub"

      Test-KwikenSevenZipArchive -SevenZipPath $sevenZipPath `
        -ArchivePath $archive.FullName -TimeoutSeconds $ArchiveTimeoutSeconds
      $archiveEntries = @(Get-KwikenSevenZipEntries `
        -SevenZipPath $sevenZipPath -ArchivePath $archive.FullName `
        -TimeoutSeconds $ArchiveTimeoutSeconds)
      $critical = Expand-KwikenValidatedCriticalArchiveFiles `
        -SevenZipPath $sevenZipPath -ArchivePath $archive.FullName `
        -Entries $archiveEntries -ExpectedVersion $script:Version `
        -Destination (Join-Path $temporaryRoot "critical") `
        -ExpectedSizes @{
          "Chrome-bin\chrome.exe" = $chrome.Bytes
          "Chrome-bin\chrome_proxy.exe" = $chromeProxy.Bytes
          "Chrome-bin\$script:Version\chrome.dll" = $chromeDll.Bytes
        } `
        -TimeoutSeconds $ArchiveTimeoutSeconds

      $archivedChrome = Get-KwikenPeArtifact -Path $critical.ChromePath `
        -Name "archived chrome.exe" -ExpectedProductName "Kwiken" `
        -ExpectedVersion $script:Version `
        -ExpectedMachine $script:KwikenAmd64Machine `
        -ExpectedMachineName "AMD64"
      $archivedChromeProxy = Get-KwikenPeArtifact `
        -Path $critical.ChromeProxyPath -Name "archived chrome_proxy.exe" `
        -ExpectedProductName "Kwiken" -ExpectedVersion $script:Version `
        -ExpectedMachine $script:KwikenAmd64Machine `
        -ExpectedMachineName "AMD64"
      $archivedChromeDll = Get-KwikenPeArtifact -Path $critical.ChromeDllPath `
        -Name "archived $script:Version\chrome.dll" `
        -ExpectedProductName "Kwiken" -ExpectedVersion $script:Version `
        -ExpectedMachine $script:KwikenAmd64Machine `
        -ExpectedMachineName "AMD64"

      [void](Assert-KwikenMatchingFileHash -ExpectedPath $snapshotChrome `
          -ActualPath $critical.ChromePath -Name "chrome.exe")
      [void](Assert-KwikenMatchingFileHash -ExpectedPath $snapshotChromeProxy `
          -ActualPath $critical.ChromeProxyPath -Name "chrome_proxy.exe")
      [void](Assert-KwikenMatchingFileHash -ExpectedPath $snapshotChromeDll `
          -ActualPath $critical.ChromeDllPath `
          -Name "chrome.dll")

      $validationResult = [pscustomobject]@{
        Status = "Passed"
        Version = $script:Version
        Revision = $script:Revision
        SourceDeltaSha256 = $sourceDeltaHash
        OutputDirectory = $outputRoot
        ChromeBytes = $chrome.Bytes
        ChromeProductName = $chrome.ProductName
        ChromeFileVersion = $chrome.FileVersion
        ChromeMachine = $chrome.Machine
        ChromeSha256 = $archivedChrome.Sha256
        ChromeProxyBytes = $chromeProxy.Bytes
        ChromeProxyMachine = $chromeProxy.Machine
        ChromeProxySha256 = $archivedChromeProxy.Sha256
        ChromeDllBytes = $chromeDll.Bytes
        ChromeDllMachine = $chromeDll.Machine
        ChromeDllSha256 = $archivedChromeDll.Sha256
        ArchiveBytes = $archive.Length
        ArchiveEntries = $critical.Layout.EntryCount
        ArchiveVersionDirectory = $critical.Layout.VersionDirectory
        MiniInstallerBytes = $miniInstaller.Bytes
        MiniInstallerProductName = $miniInstaller.ProductName
        MiniInstallerFileVersion = $miniInstaller.FileVersion
        MiniInstallerMachine = $miniInstaller.Machine
      }
    } catch {
      $validationFailure = $_
    } finally {
      if ($null -ne $temporaryRoot) {
        try {
          Remove-KwikenPrivateValidationDirectory -Path $temporaryRoot `
            -Parent $temporaryParent
        } catch {
          $cleanupFailure = $_
        }
      }
    }
    if ($null -ne $validationFailure -and $null -ne $cleanupFailure) {
      throw "Native validation failed: $($validationFailure.Exception.Message) Private cleanup also failed: $($cleanupFailure.Exception.Message)"
    }
    if ($null -ne $validationFailure) {
      throw $validationFailure
    }
    if ($null -ne $cleanupFailure) {
      throw $cleanupFailure
    }
    return $validationResult
  } finally {
    Restore-ChromiumBuildEnvironment -Snapshot $environmentSnapshot
  }
}

if (-not $isDotSourced) {
  Invoke-KwikenNativeBuildValidation -ChromiumRoot $ChromiumRoot `
    -ArchiveTimeoutSeconds $ArchiveTimeoutSeconds
}
