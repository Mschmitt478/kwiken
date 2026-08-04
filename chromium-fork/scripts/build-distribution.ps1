[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$RuntimeReadyPath,
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$RuntimeArchive,
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$RuntimeManifest,
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ExpectedReadySha256,
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$WebStoreArchive,
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$PythonPath,
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$PythonRuntimeRoot,
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ExpectedPythonSha256,
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ExpectedPythonRuntimeTreeSha256,
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$MakeNsisPath,
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$MakeNsisRuntimeRoot,
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ExpectedMakeNsisSha256,
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ExpectedMakeNsisRuntimeTreeSha256,
  [ValidateRange(30, 7200)]
  [int]$ProcessTimeoutSeconds = 1800,
  [ValidateRange(1, 1000000)]
  [int]$MaximumRuntimeFiles = 10000,
  [ValidateRange(1, 1099511627776)]
  [long]$MaximumRuntimeBytes = 4294967296,
  [ValidateRange(1, 1099511627776)]
  [long]$MaximumRuntimeArchiveBytes = 5368709120
)

. (Join-Path $PSScriptRoot "common.ps1")
. (Join-Path $PSScriptRoot "launch-support.ps1")

$script:ExpectedWebStoreSha256 =
  "627cb80dd67d16e4d2a9f105c1a1c5adf61dca63202bd577a4e4af84bd07868c"
$script:MaximumManifestBytes = 8388608
$script:MaximumReadyBytes = 65536
$script:MaximumWebStoreBytes = 33554432
$script:MaximumProcessOutputBytes = 16777216

function Assert-Sha256 {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Value,
    [Parameter(Mandatory = $true)]
    [string]$Description
  )

  $normalized = $Value.Trim().ToLowerInvariant()
  if ($normalized -cnotmatch '^[0-9a-f]{64}$') {
    throw "$Description must be a 64-character SHA-256 value."
  }
  return $normalized
}

function Get-LowerSha256 {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Assert-NoReparsePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $candidate = [IO.Path]::GetFullPath($Path)
  while (-not [string]::IsNullOrWhiteSpace($candidate)) {
    $item = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
    if ($null -ne $item -and
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Distribution inputs and work paths must not use reparse points: $candidate"
    }
    $parent = Split-Path -Parent $candidate
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $candidate) {
      break
    }
    $candidate = $parent
  }
}

function Get-RegularFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Description,
    [long]$MaximumBytes = [long]::MaxValue
  )

  $fullPath = [IO.Path]::GetFullPath(
    [Environment]::ExpandEnvironmentVariables($Path)
  )
  Assert-NoReparsePath -Path $fullPath
  $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
  if (-not ($item -is [IO.FileInfo]) -or
      ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "$Description must be a regular file: $fullPath"
  }
  if ($item.Length -gt $MaximumBytes) {
    throw "$Description exceeds the $MaximumBytes-byte limit."
  }
  return $item
}

function Get-RegularDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Description
  )

  $fullPath = [IO.Path]::GetFullPath(
    [Environment]::ExpandEnvironmentVariables($Path)
  ).TrimEnd('\')
  if ($fullPath.Equals(
      [IO.Path]::GetPathRoot($fullPath).TrimEnd('\'),
      [StringComparison]::OrdinalIgnoreCase
    )) {
    throw "$Description must be a dedicated directory, not a drive root."
  }
  Assert-NoReparsePath -Path $fullPath
  $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
  if (-not ($item -is [IO.DirectoryInfo]) -or
      ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "$Description must be a regular directory: $fullPath"
  }
  return $item
}

function Initialize-PrivateDirectoryInterop {
  if ("KwikenDistributionPrivateDirectory" -as [type]) {
    return
  }
  Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class KwikenDistributionPrivateDirectory {
    [StructLayout(LayoutKind.Sequential)]
    private struct SECURITY_ATTRIBUTES {
        public Int32 Length;
        public IntPtr SecurityDescriptor;
        public Int32 InheritHandle;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(
        string sddl, UInt32 revision, out IntPtr descriptor, out UInt32 size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateDirectory(
        string path, ref SECURITY_ATTRIBUTES attributes);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr memory);

    public static void Create(string path, string sddl) {
        IntPtr descriptor;
        UInt32 descriptorSize;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptor(
                sddl, 1, out descriptor, out descriptorSize))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            var attributes = new SECURITY_ATTRIBUTES();
            attributes.Length = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
            attributes.SecurityDescriptor = descriptor;
            attributes.InheritHandle = 0;
            if (!CreateDirectory(path, ref attributes))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        } finally { LocalFree(descriptor); }
    }
}
"@
}

function New-PrivateDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (Test-Path -LiteralPath $Path) {
    throw "Refusing to reuse an existing private staging path: $Path"
  }
  $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $sddl = "O:{0}G:{0}D:P(A;OICI;FA;;;{0})(A;OICI;FA;;;SY)" -f `
    $currentSid.Value
  $created = $false
  try {
    Initialize-PrivateDirectoryInterop
    [KwikenDistributionPrivateDirectory]::Create(
      [IO.Path]::GetFullPath($Path),
      $sddl
    )
    $created = $true
    $actual = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $owner = $actual.GetOwner([Security.Principal.SecurityIdentifier])
    if ($owner -ne $currentSid -or -not $actual.AreAccessRulesProtected) {
      throw "The distribution staging directory did not receive a protected ACL."
    }
  } catch {
    $creationError = $_
    if ($created -and (Test-Path -LiteralPath $Path -PathType Container)) {
      try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
      } catch {
        throw "Private staging setup and cleanup failed: $($creationError.Exception.Message); $($_.Exception.Message)"
      }
    }
    throw $creationError
  }
}

function Remove-PrivateDistributionDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Parent
  )

  $fullPath = [IO.Path]::GetFullPath($Path)
  $fullParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
  if (-not (Split-Path -Parent $fullPath).Equals(
      $fullParent,
      [StringComparison]::OrdinalIgnoreCase
    ) -or
      (Split-Path -Leaf $fullPath) -cnotmatch '^\.Kwiken-Distribution-[0-9a-f]{32}\.staging$') {
    throw "Refusing to remove an unexpected distribution path: $fullPath"
  }
  if (Test-Path -LiteralPath $fullPath) {
    Remove-Item -LiteralPath $fullPath -Recurse -Force -ErrorAction Stop
  }
}

function Copy-InputSnapshot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [Parameter(Mandatory = $true)]
    [string]$Destination,
    [Parameter(Mandatory = $true)]
    [long]$MaximumBytes
  )

  $sourceItem = Get-RegularFile -Path $Source -Description "Distribution input" `
    -MaximumBytes $MaximumBytes
  $input = $null
  $output = $null
  try {
    $input = [IO.File]::Open(
      $sourceItem.FullName,
      [IO.FileMode]::Open,
      [IO.FileAccess]::Read,
      [IO.FileShare]::Read
    )
    if ($input.Length -ne $sourceItem.Length -or $input.Length -gt $MaximumBytes) {
      throw "A distribution input changed before it could be snapshotted: $Source"
    }
    $output = [IO.File]::Open(
      $Destination,
      [IO.FileMode]::CreateNew,
      [IO.FileAccess]::Write,
      [IO.FileShare]::None
    )
    $input.CopyTo($output, 1048576)
    $output.Flush($true)
  } finally {
    if ($null -ne $output) { $output.Dispose() }
    if ($null -ne $input) { $input.Dispose() }
  }
  $snapshot = Get-Item -LiteralPath $Destination -Force -ErrorAction Stop
  if ($snapshot.Length -ne $sourceItem.Length) {
    throw "A distribution input snapshot was truncated: $Source"
  }
  return $snapshot
}

function Get-DirectoryTreeSha256 {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Root,
    [int]$MaximumFiles = 50000,
    [long]$MaximumBytes = 2147483648
  )

  $rootItem = Get-RegularDirectory -Path $Root -Description "Tool runtime root"
  $fullRoot = $rootItem.FullName.TrimEnd('\')
  $files = @()
  $totalBytes = [long]0
  foreach ($item in Get-ChildItem -LiteralPath $fullRoot -Recurse -Force -ErrorAction Stop) {
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Tool runtime must not contain reparse points: $($item.FullName)"
    }
    if ($item -is [IO.FileInfo]) {
      $totalBytes += $item.Length
      if ($totalBytes -gt $MaximumBytes) {
        throw "Tool runtime exceeds the $MaximumBytes-byte limit."
      }
      $files += $item.FullName.Substring($fullRoot.Length + 1).Replace('\', '/')
      if ($files.Count -gt $MaximumFiles) {
        throw "Tool runtime contains more than $MaximumFiles files."
      }
    }
  }
  [Array]::Sort($files, [StringComparer]::Ordinal)
  $manifest = [IO.MemoryStream]::new()
  $encoding = [Text.UTF8Encoding]::new($false, $true)
  $sha256 = [Security.Cryptography.SHA256]::Create()
  try {
    foreach ($relative in $files) {
      if ($relative.IndexOfAny(@([char]0, [char]10, [char]13)) -ge 0) {
        throw "Tool runtime contains an unsafe path: '$relative'"
      }
      $filePath = Join-Path $fullRoot $relative.Replace('/', '\')
      $file = Get-RegularFile -Path $filePath -Description "Tool runtime file"
      $record = "$relative$([char]0)$($file.Length)$([char]0)$(Get-LowerSha256 -Path $file.FullName)`n"
      $recordBytes = $encoding.GetBytes($record)
      $manifest.Write($recordBytes, 0, $recordBytes.Length)
    }
    $manifest.Position = 0
    return -join ($sha256.ComputeHash($manifest) | ForEach-Object {
        $_.ToString("x2")
      })
  } finally {
    $sha256.Dispose()
    $manifest.Dispose()
  }
}

function Copy-DirectorySnapshot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [Parameter(Mandatory = $true)]
    [string]$Destination,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedTreeSha256
  )

  $sourceItem = Get-RegularDirectory -Path $Source -Description "Tool runtime root"
  if (Test-Path -LiteralPath $Destination) {
    throw "Refusing to reuse a tool-runtime snapshot path: $Destination"
  }
  [void][IO.Directory]::CreateDirectory($Destination)
  $sourceRoot = $sourceItem.FullName.TrimEnd('\')
  $copiedFiles = 0
  $copiedBytes = [long]0
  foreach ($item in Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force `
      -ErrorAction Stop | Sort-Object FullName) {
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Tool runtime must not contain reparse points: $($item.FullName)"
    }
    $relative = $item.FullName.Substring($sourceRoot.Length + 1)
    $target = Join-Path $Destination $relative
    if ($item -is [IO.DirectoryInfo]) {
      [void][IO.Directory]::CreateDirectory($target)
    } else {
      $copiedFiles++
      $copiedBytes += $item.Length
      if ($copiedFiles -gt 50000 -or $copiedBytes -gt 2147483648) {
        throw "Tool runtime exceeds its snapshot file or byte limit."
      }
      $targetParent = Split-Path -Parent $target
      if (-not (Test-Path -LiteralPath $targetParent)) {
        [void][IO.Directory]::CreateDirectory($targetParent)
      }
      [void](Copy-InputSnapshot -Source $item.FullName -Destination $target `
          -MaximumBytes 2147483648)
    }
  }
  $snapshotHash = Get-DirectoryTreeSha256 -Root $Destination
  $sourceHash = Get-DirectoryTreeSha256 -Root $sourceRoot
  if ($snapshotHash -cne $ExpectedTreeSha256 -or $sourceHash -cne $ExpectedTreeSha256) {
    throw "Tool runtime tree does not match its trusted SHA-256."
  }
  return $snapshotHash
}

function Get-RequiredProperty {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Object,
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [string]$Context
  )

  if ($null -eq $Object) {
    throw "$Context is missing."
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    throw "$Context.$Name is missing."
  }
  return $property.Value
}

function Get-RequiredString {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Object,
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [string]$Context
  )

  $value = Get-RequiredProperty -Object $Object -Name $Name -Context $Context
  if (-not ($value -is [string]) -or [string]::IsNullOrWhiteSpace($value)) {
    throw "$Context.$Name must be a non-empty string."
  }
  return $value
}

function Assert-ExactProperties {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Object,
    [Parameter(Mandatory = $true)]
    [string[]]$Names,
    [Parameter(Mandatory = $true)]
    [string]$Context
  )

  $actual = @($Object.PSObject.Properties.Name | Sort-Object)
  $expected = @($Names | Sort-Object)
  if ($actual.Count -ne $expected.Count -or
      (Compare-Object -ReferenceObject $expected -DifferenceObject $actual)) {
    throw "$Context has an unexpected schema."
  }
}

function Read-BoundedJson {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [int]$MaximumBytes,
    [Parameter(Mandatory = $true)]
    [string]$Description
  )

  $item = Get-RegularFile -Path $Path -Description $Description -MaximumBytes $MaximumBytes
  $bytes = [IO.File]::ReadAllBytes($item.FullName)
  if ($bytes.Length -gt $MaximumBytes) {
    throw "$Description exceeds the JSON input limit."
  }
  try {
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    return $text | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "$Description is not strict UTF-8 JSON: $($_.Exception.Message)"
  }
}

function Initialize-DistributionJobInterop {
  if (("KwikenDistributionJob" -as [type]) -and
      ("KwikenDistributionCapture" -as [type])) {
    return
  }
  Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

public static class KwikenDistributionJob {
    [StructLayout(LayoutKind.Sequential)]
    private struct BASIC_LIMITS {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public UInt32 LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public UInt32 ActiveProcessLimit;
        public UIntPtr Affinity;
        public UInt32 PriorityClass;
        public UInt32 SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS {
        public UInt64 ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public UInt64 ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct EXTENDED_LIMITS {
        public BASIC_LIMITS BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int type, IntPtr value, UInt32 length);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    public static IntPtr CreateKillOnClose() {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        var limits = new EXTENDED_LIMITS();
        limits.BasicLimitInformation.LimitFlags = 0x00002000;
        int length = Marshal.SizeOf(typeof(EXTENDED_LIMITS));
        IntPtr value = Marshal.AllocHGlobal(length);
        try {
            Marshal.StructureToPtr(limits, value, false);
            if (!SetInformationJobObject(job, 9, value, (UInt32)length))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return job;
        } catch { CloseHandle(job); throw; }
        finally { Marshal.FreeHGlobal(value); }
    }
    public static void Assign(IntPtr job, IntPtr process) {
        if (!AssignProcessToJobObject(job, process))
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    public static void Close(IntPtr job) {
        if (job != IntPtr.Zero && !CloseHandle(job))
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }
}

public sealed class KwikenDistributionCapture {
    private readonly Stream input;
    private readonly int maximumBytes;
    private readonly MemoryStream content = new MemoryStream();
    private Exception failure;
    public volatile bool LimitExceeded;
    private KwikenDistributionCapture(Stream input, int maximumBytes) {
        this.input = input; this.maximumBytes = maximumBytes;
        Completion = Task.Factory.StartNew(Read, CancellationToken.None,
            TaskCreationOptions.LongRunning, TaskScheduler.Default);
    }
    public Task Completion { get; private set; }
    public static KwikenDistributionCapture Start(Stream input, int maximumBytes) {
        return new KwikenDistributionCapture(input, maximumBytes);
    }
    private void Read() {
        byte[] buffer = new byte[8192];
        try {
            while (true) {
                int count = input.Read(buffer, 0, buffer.Length);
                if (count == 0) return;
                if (content.Length + count > maximumBytes) { LimitExceeded = true; return; }
                content.Write(buffer, 0, count);
            }
        } catch (Exception error) { failure = error; }
    }
    public string Text() {
        if (failure != null) throw new IOException("Could not capture process output.", failure);
        if (LimitExceeded) throw new InvalidOperationException("Process output exceeded its limit.");
        return new System.Text.UTF8Encoding(false, false).GetString(content.ToArray());
    }
}
"@
}

function Invoke-BoundedProcess {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [string[]]$Arguments = @(),
    [Parameter(Mandatory = $true)]
    [string]$WorkingDirectory,
    [Parameter(Mandatory = $true)]
    [string]$Description,
    [hashtable]$EnvironmentVariables = @{},
    [switch]$IsolatedPython
  )

  $specification = [ordered]@{
    filePath = $FilePath
    arguments = @($Arguments)
    workingDirectory = $WorkingDirectory
  }
  $specificationBase64 = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes(($specification | ConvertTo-Json -Compress -Depth 4))
  )
  $gateName = "Local\Kwiken-Distribution-$([Guid]::NewGuid().ToString('N'))"
  $gate = [Threading.EventWaitHandle]::new(
    $false,
    [Threading.EventResetMode]::ManualReset,
    $gateName
  )
  $wrapperSource = @'
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$gate = $null
try {
  $specification = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String($env:KWIKEN_DISTRIBUTION_TARGET)
  ) | ConvertFrom-Json
  $gate = [Threading.EventWaitHandle]::OpenExisting($env:KWIKEN_DISTRIBUTION_GATE)
  [Environment]::SetEnvironmentVariable("KWIKEN_DISTRIBUTION_TARGET", $null, "Process")
  [Environment]::SetEnvironmentVariable("KWIKEN_DISTRIBUTION_GATE", $null, "Process")
  if (-not $gate.WaitOne(60000)) { throw "Distribution process admission timed out." }
  Set-Location -LiteralPath ([string]$specification.workingDirectory)
  $targetArguments = @($specification.arguments | ForEach-Object { [string]$_ })
  & ([string]$specification.filePath) @targetArguments
  if ($null -eq $LASTEXITCODE) { exit 0 }
  exit $LASTEXITCODE
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 254
} finally {
  if ($null -ne $gate) { $gate.Dispose() }
}
'@
  $encodedWrapper = [Convert]::ToBase64String(
    [Text.Encoding]::Unicode.GetBytes($wrapperSource)
  )
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = (Get-Process -Id $PID).Path
  $startInfo.Arguments = Join-WindowsCommandLineArguments -Arguments @(
    "-NoLogo", "-NoProfile", "-NonInteractive", "-OutputFormat", "Text",
    "-EncodedCommand", $encodedWrapper
  )
  $startInfo.WorkingDirectory = $WorkingDirectory
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
  $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
  if ($IsolatedPython) {
    foreach ($name in @($startInfo.EnvironmentVariables.Keys)) {
      if ($name.ToString().StartsWith("PYTHON", [StringComparison]::OrdinalIgnoreCase)) {
        $startInfo.EnvironmentVariables.Remove($name.ToString())
      }
    }
  }
  foreach ($name in $EnvironmentVariables.Keys) {
    $startInfo.EnvironmentVariables[[string]$name] = [string]$EnvironmentVariables[$name]
  }
  $startInfo.EnvironmentVariables["KWIKEN_DISTRIBUTION_TARGET"] = $specificationBase64
  $startInfo.EnvironmentVariables["KWIKEN_DISTRIBUTION_GATE"] = $gateName

  Initialize-DistributionJobInterop
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  $job = [IntPtr]::Zero
  $started = $false
  try {
    $job = [KwikenDistributionJob]::CreateKillOnClose()
    if (-not $process.Start()) { throw "Windows did not start $Description." }
    $started = $true
    [KwikenDistributionJob]::Assign($job, $process.Handle)
    [void]$gate.Set()
    $stdout = [KwikenDistributionCapture]::Start(
      $process.StandardOutput.BaseStream,
      $script:MaximumProcessOutputBytes
    )
    $stderr = [KwikenDistributionCapture]::Start(
      $process.StandardError.BaseStream,
      $script:MaximumProcessOutputBytes
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($ProcessTimeoutSeconds)
    while (-not $process.HasExited -and
        -not $stdout.LimitExceeded -and
        -not $stderr.LimitExceeded -and
        [DateTime]::UtcNow -lt $deadline) {
      [void]$process.WaitForExit(100)
      $process.Refresh()
    }
    if (-not $process.HasExited -or $stdout.LimitExceeded -or $stderr.LimitExceeded) {
      [KwikenDistributionJob]::Close($job)
      $job = [IntPtr]::Zero
      [void]$process.WaitForExit(10000)
      throw "$Description exceeded its time or output limit; its process job was terminated."
    }
    $exitCode = $process.ExitCode
    [KwikenDistributionJob]::Close($job)
    $job = [IntPtr]::Zero
    if (-not $stdout.Completion.Wait(10000) -or -not $stderr.Completion.Wait(10000)) {
      throw "$Description did not close its output streams."
    }
    $standardOutput = $stdout.Text()
    $standardError = $stderr.Text()
    if ($exitCode -ne 0) {
      throw "$Description failed with exit code $exitCode`: $standardError"
    }
    return [pscustomobject]@{
      StandardOutput = $standardOutput
      StandardError = $standardError
      ExitCode = $exitCode
    }
  } finally {
    if ($job -ne [IntPtr]::Zero) {
      [KwikenDistributionJob]::Close($job)
    }
    if ($started -and -not $process.HasExited) {
      try { $process.Kill() } catch {}
    }
    $gate.Dispose()
    $process.Dispose()
  }
}

function Import-VisualStudioEnvironment {
  param(
    [Parameter(Mandatory = $true)]
    [string]$WorkDirectory
  )

  $vsWhere = Get-VsWherePath
  if (-not $vsWhere) {
    throw "Visual Studio Installer's vswhere.exe was not found."
  }
  $vsWhere = (Get-RegularFile -Path $vsWhere -Description "vswhere.exe").FullName
  $query = Invoke-BoundedProcess -FilePath $vsWhere -Arguments @(
    "-latest", "-products", "*",
    "-version", "[$script:RequiredVisualStudioMajorVersion.0,$($script:RequiredVisualStudioMajorVersion + 1).0)",
    "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
    "-property", "installationPath"
  ) -WorkingDirectory $WorkDirectory -Description "vswhere.exe"
  $installationPath = @($query.StandardOutput -split "`r?`n" |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -First 1
  if (-not $installationPath) {
    throw "A Visual Studio installation with C++ build tools was not found."
  }
  $vsDevCmd = Join-Path $installationPath.Trim() "Common7\Tools\VsDevCmd.bat"
  [void](Get-RegularFile -Path $vsDevCmd -Description "VsDevCmd.bat")
  if ($vsDevCmd -match '[\r\n"%!&|<>\^]') {
    throw "Visual Studio's developer-command path contains unsafe cmd.exe characters."
  }
  $environmentScript = Join-Path $WorkDirectory "load-vs-environment.cmd"
  [IO.File]::WriteAllLines(
    $environmentScript,
    @(
      "@echo off",
      "call `"$vsDevCmd`" -no_logo -arch=x64 -host_arch=x64 >nul",
      "if errorlevel 1 exit /b %errorlevel%",
      "set"
    ),
    [Text.Encoding]::ASCII
  )
  $commandShell = Join-Path $env:SystemRoot "System32\cmd.exe"
  $environmentResult = Invoke-BoundedProcess -FilePath $commandShell `
    -Arguments @("/d", "/c", "load-vs-environment.cmd") `
    -WorkingDirectory $WorkDirectory -Description "VsDevCmd.bat"
  $environment = @{}
  foreach ($line in ($environmentResult.StandardOutput -split "`r?`n")) {
    $separator = $line.IndexOf('=')
    if ($separator -gt 0) {
      $environment[$line.Substring(0, $separator)] = $line.Substring($separator + 1)
    }
  }
  if (-not $environment.ContainsKey("PATH")) {
    throw "Visual Studio did not return a PATH environment."
  }
  return $environment
}

function Find-ExecutableInPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [string]$PathValue
  )

  foreach ($directory in ($PathValue -split ';')) {
    $trimmed = $directory.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
    $candidate = Join-Path $trimmed $Name
    $item = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
    if ($null -ne $item -and $item -is [IO.FileInfo] -and
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
      return (Get-RegularFile -Path $item.FullName -Description $Name).FullName
    }
  }
  throw "$Name was not present in Visual Studio's PATH."
}

function Expand-PinnedWebStoreArchive {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,
    [Parameter(Mandatory = $true)]
    [string]$Destination
  )

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [void][IO.Directory]::CreateDirectory($Destination)
  $destinationPrefix = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
  $expectedPrefix = "chromium-web-store-1.5.5.3/src/"
  $seen = @{}
  $selectedFiles = 0
  $totalLength = [long]0
  $stream = [IO.File]::Open(
    $ArchivePath,
    [IO.FileMode]::Open,
    [IO.FileAccess]::Read,
    [IO.FileShare]::Read
  )
  $archive = $null
  try {
    $archive = [IO.Compression.ZipArchive]::new(
      $stream,
      [IO.Compression.ZipArchiveMode]::Read,
      $false
    )
    if ($archive.Entries.Count -gt 4096) {
      throw "The Web Store archive contains too many entries."
    }
    foreach ($entry in $archive.Entries) {
      $name = $entry.FullName
      if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains('\') -or
          $name.Contains(':') -or $name.StartsWith('/') -or
          $name -match '(^|/)\.\.?(?:/|$)' -or
          (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000 -or
          ($entry.ExternalAttributes -band 0x400) -ne 0) {
        throw "The Web Store archive contains an unsafe entry: '$name'"
      }
      $key = $name.ToLowerInvariant()
      if ($seen.ContainsKey($key)) {
        throw "The Web Store archive contains a duplicate entry: '$name'"
      }
      $seen[$key] = $true
      $totalLength += $entry.Length
      if ($totalLength -gt 268435456) {
        throw "The Web Store archive exceeds its uncompressed-size limit."
      }
      if (-not $name.StartsWith($expectedPrefix, [StringComparison]::Ordinal)) {
        continue
      }
      $relative = $name.Substring($expectedPrefix.Length)
      if ([string]::IsNullOrEmpty($relative)) { continue }
      $target = [IO.Path]::GetFullPath(
        (Join-Path $Destination ($relative.Replace('/', '\')))
      )
      if (-not $target.StartsWith($destinationPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The Web Store archive entry escapes its destination: '$name'"
      }
      if ($name.EndsWith('/')) {
        [void][IO.Directory]::CreateDirectory($target)
        continue
      }
      [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
      $input = $entry.Open()
      $output = $null
      try {
        $output = [IO.File]::Open(
          $target,
          [IO.FileMode]::CreateNew,
          [IO.FileAccess]::Write,
          [IO.FileShare]::None
        )
        $input.CopyTo($output, 65536)
        $output.Flush($true)
      } finally {
        if ($null -ne $output) { $output.Dispose() }
        $input.Dispose()
      }
      if ((Get-Item -LiteralPath $target -Force).Length -ne $entry.Length) {
        throw "The Web Store archive entry was truncated: '$name'"
      }
      $selectedFiles++
    }
  } finally {
    if ($null -ne $archive) { $archive.Dispose() }
    $stream.Dispose()
  }
  if ($selectedFiles -lt 1) {
    throw "The Web Store archive did not contain its pinned src directory."
  }
  $manifestPath = Join-Path $Destination "manifest.json"
  $extensionManifest = Read-BoundedJson -Path $manifestPath -MaximumBytes 1048576 `
    -Description "Chromium Web Store extension manifest"
  if ($extensionManifest.version -cne "1.5.5.3" -or
      [int]$extensionManifest.manifest_version -ne 3) {
    throw "The Chromium Web Store extension manifest did not match 1.5.5.3/MV3."
  }
}

$expectedReady = Assert-Sha256 -Value $ExpectedReadySha256 `
  -Description "ExpectedReadySha256"
$expectedPython = Assert-Sha256 -Value $ExpectedPythonSha256 `
  -Description "ExpectedPythonSha256"
$expectedPythonRuntimeTree = Assert-Sha256 `
  -Value $ExpectedPythonRuntimeTreeSha256 `
  -Description "ExpectedPythonRuntimeTreeSha256"
$expectedMakeNsis = Assert-Sha256 -Value $ExpectedMakeNsisSha256 `
  -Description "ExpectedMakeNsisSha256"
$expectedMakeNsisRuntimeTree = Assert-Sha256 `
  -Value $ExpectedMakeNsisRuntimeTreeSha256 `
  -Description "ExpectedMakeNsisRuntimeTreeSha256"

$readyInput = Get-RegularFile -Path $RuntimeReadyPath -Description "Runtime READY file" `
  -MaximumBytes $script:MaximumReadyBytes
$archiveInput = Get-RegularFile -Path $RuntimeArchive -Description "Runtime archive" `
  -MaximumBytes $MaximumRuntimeArchiveBytes
$manifestInput = Get-RegularFile -Path $RuntimeManifest -Description "Runtime manifest" `
  -MaximumBytes $script:MaximumManifestBytes
$webStoreInput = Get-RegularFile -Path $WebStoreArchive -Description "Web Store archive" `
  -MaximumBytes $script:MaximumWebStoreBytes
$pythonInput = Get-RegularFile -Path $PythonPath -Description "Verifier python3.exe"
$pythonRootInput = Get-RegularDirectory -Path $PythonRuntimeRoot `
  -Description "Verifier Python runtime root"
$makeNsisInput = Get-RegularFile -Path $MakeNsisPath -Description "makensis.exe"
$makeNsisRootInput = Get-RegularDirectory -Path $MakeNsisRuntimeRoot `
  -Description "NSIS runtime root"

$pythonRootPrefix = $pythonRootInput.FullName.TrimEnd('\') + '\'
if (-not $pythonInput.FullName.StartsWith(
    $pythonRootPrefix,
    [StringComparison]::OrdinalIgnoreCase
  ) -or
    -not $pythonInput.DirectoryName.Equals(
      $pythonRootInput.FullName,
      [StringComparison]::OrdinalIgnoreCase
    )) {
  throw "Verifier python3.exe must be contained by PythonRuntimeRoot."
}
$pythonRelativePath = $pythonInput.FullName.Substring($pythonRootPrefix.Length)
if ($pythonInput.Name -cne "python3.exe") {
  throw "Verifier Python must be the direct python3.exe runtime executable."
}
$makeNsisRootPrefix = $makeNsisRootInput.FullName.TrimEnd('\') + '\'
if (-not $makeNsisInput.DirectoryName.Equals(
    $makeNsisRootInput.FullName,
    [StringComparison]::OrdinalIgnoreCase
  ) -or $makeNsisInput.Name -cne "makensis.exe") {
  throw "makensis.exe must be a direct child of MakeNsisRuntimeRoot."
}
$makeNsisRelativePath = $makeNsisInput.FullName.Substring(
  $makeNsisRootPrefix.Length
)

$releaseDirectory = [IO.Path]::GetFullPath((Split-Path -Parent $readyInput.FullName))
foreach ($input in @($archiveInput, $manifestInput)) {
  if (-not $input.DirectoryName.Equals(
      $releaseDirectory,
      [StringComparison]::OrdinalIgnoreCase
    )) {
    throw "READY, runtime archive, and runtime manifest must share one release directory."
  }
}
if ((Get-LowerSha256 -Path $pythonInput.FullName) -cne $expectedPython) {
  throw "Verifier Python SHA-256 does not match the trusted value."
}
if ((Get-DirectoryTreeSha256 -Root $pythonRootInput.FullName) -cne
    $expectedPythonRuntimeTree) {
  throw "Verifier Python runtime tree SHA-256 does not match the trusted value."
}
if ((Get-LowerSha256 -Path $makeNsisInput.FullName) -cne $expectedMakeNsis) {
  throw "makensis.exe SHA-256 does not match the trusted value."
}
if ((Get-DirectoryTreeSha256 -Root $makeNsisRootInput.FullName) -cne
    $expectedMakeNsisRuntimeTree) {
  throw "NSIS runtime tree SHA-256 does not match the trusted value."
}

$cacheRoot = Join-Path $script:ForkRoot ".cache"
if (-not (Test-Path -LiteralPath $cacheRoot)) {
  [void][IO.Directory]::CreateDirectory($cacheRoot)
}
Assert-NoReparsePath -Path $cacheRoot
$workRoot = Join-Path $cacheRoot `
  (".Kwiken-Distribution-" + [Guid]::NewGuid().ToString("N") + ".staging")
New-PrivateDirectory -Path $workRoot
$published = $false
$publishTemporary = $null
try {
  $inputRoot = Join-Path $workRoot "inputs"
  $packageRoot = Join-Path $workRoot "package"
  $launcherRoot = Join-Path $workRoot "launcher"
  $publicationRoot = Join-Path $workRoot "publication"
  foreach ($directory in @($inputRoot, $packageRoot, $launcherRoot, $publicationRoot)) {
    [void][IO.Directory]::CreateDirectory($directory)
  }

  $readySnapshot = Join-Path $inputRoot "RELEASE.READY.json"
  [void](Copy-InputSnapshot -Source $readyInput.FullName -Destination $readySnapshot `
      -MaximumBytes $script:MaximumReadyBytes)
  if ((Get-LowerSha256 -Path $readySnapshot) -cne $expectedReady) {
    throw "Runtime READY SHA-256 does not match the trusted value."
  }
  $ready = Read-BoundedJson -Path $readySnapshot -MaximumBytes $script:MaximumReadyBytes `
    -Description "Runtime READY file"
  Assert-ExactProperties -Object $ready `
    -Names @("schemaVersion", "releaseVersion", "archive", "manifest") `
    -Context "READY"
  if ([int](Get-RequiredProperty -Object $ready -Name "schemaVersion" -Context "READY") -ne 1 -or
      (Get-RequiredString -Object $ready -Name "releaseVersion" -Context "READY") -cne $script:ReleaseVersion) {
    throw "Runtime READY does not identify $script:ReleaseVersion/schema 1."
  }
  $readyArchive = Get-RequiredProperty -Object $ready -Name "archive" -Context "READY"
  $readyManifest = Get-RequiredProperty -Object $ready -Name "manifest" -Context "READY"
  Assert-ExactProperties -Object $readyArchive -Names @("fileName", "sha256") `
    -Context "READY.archive"
  Assert-ExactProperties -Object $readyManifest -Names @("fileName", "sha256") `
    -Context "READY.manifest"
  $expectedArchiveName = "Kwiken-runtime-$script:ReleaseVersion-windows-x64.zip"
  $expectedManifestName =
    "Kwiken-runtime-$script:ReleaseVersion-windows-x64.provenance.json"
  if ((Get-RequiredString -Object $readyArchive -Name "fileName" -Context "READY.archive") -cne $expectedArchiveName -or
      $archiveInput.Name -cne $expectedArchiveName -or
      (Get-RequiredString -Object $readyManifest -Name "fileName" -Context "READY.manifest") -cne $expectedManifestName -or
      $manifestInput.Name -cne $expectedManifestName -or
      $readyInput.Name -cne "RELEASE.READY.json") {
    throw "The runtime handoff does not use export-runtime.ps1's canonical file names."
  }
  $readyArchiveSha256 = Assert-Sha256 `
    -Value (Get-RequiredString -Object $readyArchive -Name "sha256" -Context "READY.archive") `
    -Description "READY archive SHA-256"
  $readyManifestSha256 = Assert-Sha256 `
    -Value (Get-RequiredString -Object $readyManifest -Name "sha256" -Context "READY.manifest") `
    -Description "READY manifest SHA-256"

  $archiveSnapshot = Join-Path $inputRoot $expectedArchiveName
  $manifestSnapshot = Join-Path $inputRoot $expectedManifestName
  $webStoreSnapshot = Join-Path $inputRoot "chromium-web-store-v1.5.5.3.zip"
  [void](Copy-InputSnapshot -Source $archiveInput.FullName -Destination $archiveSnapshot `
      -MaximumBytes $MaximumRuntimeArchiveBytes)
  [void](Copy-InputSnapshot -Source $manifestInput.FullName -Destination $manifestSnapshot `
      -MaximumBytes $script:MaximumManifestBytes)
  [void](Copy-InputSnapshot -Source $webStoreInput.FullName -Destination $webStoreSnapshot `
      -MaximumBytes $script:MaximumWebStoreBytes)
  if ((Get-LowerSha256 -Path $archiveSnapshot) -cne $readyArchiveSha256) {
    throw "Runtime archive SHA-256 does not match authenticated READY metadata."
  }
  if ((Get-LowerSha256 -Path $manifestSnapshot) -cne $readyManifestSha256) {
    throw "Runtime manifest SHA-256 does not match authenticated READY metadata."
  }
  if ((Get-LowerSha256 -Path $webStoreSnapshot) -cne $script:ExpectedWebStoreSha256) {
    throw "Chromium Web Store archive SHA-256 does not match pinned 1.5.5.3."
  }

  # The manifest is parsed only after its digest is authenticated by the
  # externally trusted READY digest. Every parsed value is still passed as an
  # exact --expect-* value so runtime_archive.py performs one complete strict
  # provenance/content verification before extraction.
  $manifest = Read-BoundedJson -Path $manifestSnapshot `
    -MaximumBytes $script:MaximumManifestBytes -Description "Runtime manifest"
  $product = Get-RequiredProperty -Object $manifest -Name "product" -Context "manifest"
  $source = Get-RequiredProperty -Object $manifest -Name "source" -Context "manifest"
  $nativeBuild = Get-RequiredProperty -Object $manifest -Name "nativeBuild" -Context "manifest"
  $artifact = Get-RequiredProperty -Object $manifest -Name "artifact" -Context "manifest"
  $runtime = Get-RequiredProperty -Object $manifest -Name "runtime" -Context "manifest"
  $kwiken = Get-RequiredProperty -Object $source -Name "kwiken" -Context "source"
  $chromium = Get-RequiredProperty -Object $source -Name "chromium" -Context "source"
  $dependencyState = Get-RequiredProperty -Object $source -Name "dependencyState" -Context "source"
  $gnArgs = Get-RequiredProperty -Object $source -Name "gnArgs" -Context "source"
  $patchSet = Get-RequiredProperty -Object $source -Name "patchSet" -Context "source"
  $invocation = Get-RequiredProperty -Object $nativeBuild -Name "buildInvocation" `
    -Context "nativeBuild"
  $toolchain = Get-RequiredProperty -Object $nativeBuild -Name "toolchain" `
    -Context "nativeBuild"
  if ((Get-RequiredString -Object $product -Name "version" -Context "product") -cne $script:Version -or
      (Get-RequiredString -Object $product -Name "packageRevision" -Context "product") -cne $script:PackageRevision -or
      (Get-RequiredString -Object $product -Name "releaseVersion" -Context "product") -cne $script:ReleaseVersion -or
      (Get-RequiredString -Object $chromium -Name "revision" -Context "source.chromium") -cne $script:Revision -or
      (Get-RequiredString -Object $source -Name "depotToolsRevision" -Context "source") -cne $script:DepotToolsRevision -or
      (Get-RequiredString -Object $source -Name "appliedSourceTreeSha256" -Context "source") -cne $script:ExpectedSourceDeltaSha256 -or
      [bool](Get-RequiredProperty -Object $kwiken -Name "dirty" -Context "source.kwiken")) {
    throw "The authenticated runtime manifest does not match this clean pinned Kwiken release."
  }
  if ((Get-RequiredString -Object $toolchain -Name "pythonSha256" `
        -Context "nativeBuild.toolchain") -cne $expectedPython -or
      (Get-RequiredString -Object $toolchain -Name "pythonRuntimeTreeSha256" `
        -Context "nativeBuild.toolchain") -cne $expectedPythonRuntimeTree) {
    throw "The verifier Python runtime is not the pinned runtime authenticated by READY."
  }
  $artifactSize = [long](Get-RequiredProperty -Object $artifact -Name "size" -Context "artifact")
  if ($artifactSize -ne (Get-Item -LiteralPath $archiveSnapshot -Force).Length) {
    throw "Authenticated runtime artifact size does not match the snapshot."
  }
  $archiveRoot = Get-RequiredString -Object $runtime -Name "archiveRoot" -Context "runtime"
  if ($archiveRoot -cne "Kwiken-runtime-$script:ReleaseVersion") {
    throw "Authenticated runtime archiveRoot is not canonical."
  }

  $runtimeArchiveToolSource = Join-Path $script:ForkRoot "distribution\runtime_archive.py"
  [void](Get-RegularFile -Path $runtimeArchiveToolSource `
      -Description "runtime_archive.py" -MaximumBytes 4194304)
  $runtimeArchiveTool = Join-Path $inputRoot "runtime_archive.py"
  [void](Copy-InputSnapshot -Source $runtimeArchiveToolSource `
      -Destination $runtimeArchiveTool -MaximumBytes 4194304)
  $runtimeArchiveToolSha256 = Get-LowerSha256 -Path $runtimeArchiveTool
  $pythonSnapshotRoot = Join-Path $workRoot "verifier-python"
  [void](Copy-DirectorySnapshot -Source $pythonRootInput.FullName `
      -Destination $pythonSnapshotRoot `
      -ExpectedTreeSha256 $expectedPythonRuntimeTree)
  $pythonSnapshotPath = Join-Path $pythonSnapshotRoot $pythonRelativePath
  if ((Get-LowerSha256 -Path $pythonSnapshotPath) -cne $expectedPython) {
    throw "Private verifier Python executable does not match its trusted SHA-256."
  }
  $makeNsisSnapshotRoot = Join-Path $workRoot "nsis-runtime"
  [void](Copy-DirectorySnapshot -Source $makeNsisRootInput.FullName `
      -Destination $makeNsisSnapshotRoot `
      -ExpectedTreeSha256 $expectedMakeNsisRuntimeTree)
  $makeNsisSnapshotPath = Join-Path $makeNsisSnapshotRoot $makeNsisRelativePath
  if ((Get-LowerSha256 -Path $makeNsisSnapshotPath) -cne $expectedMakeNsis) {
    throw "Private makensis.exe does not match its trusted SHA-256."
  }
  $extractRoot = Join-Path $workRoot "verified-runtime"
  $verifyArguments = [Collections.Generic.List[string]]::new()
  foreach ($argument in @(
      "-I", "-S", "-B", $runtimeArchiveTool, "verify",
      "--archive", $archiveSnapshot,
      "--manifest", $manifestSnapshot,
      "--extract-to", $extractRoot,
      "--expect-version", $script:Version,
      "--expect-package-revision", $script:PackageRevision,
      "--expect-release-version", $script:ReleaseVersion,
      "--expect-kwiken-revision", (Get-RequiredString -Object $kwiken -Name "revision" -Context "source.kwiken"),
      "--expect-chromium-revision", $script:Revision,
      "--expect-depot-tools-revision", $script:DepotToolsRevision,
      "--expect-source-delta-sha256", $script:ExpectedSourceDeltaSha256,
      "--expect-dependency-state-tree-sha256", (Get-RequiredString -Object $dependencyState -Name "treeSha256" -Context "source.dependencyState"),
      "--expect-gn-args-sha256", (Get-RequiredString -Object $gnArgs -Name "sha256" -Context "source.gnArgs"),
      "--expect-artifact-sha256", $readyArchiveSha256,
      "--expect-artifact-size", [string]$artifactSize,
      "--expect-chrome-7z-sha256", (Get-RequiredString -Object $nativeBuild -Name "chrome7zSha256" -Context "nativeBuild"),
      "--expect-chrome-exe-sha256", (Get-RequiredString -Object $nativeBuild -Name "chromeExeSha256" -Context "nativeBuild"),
      "--expect-mini-installer-sha256", (Get-RequiredString -Object $nativeBuild -Name "miniInstallerSha256" -Context "nativeBuild"),
      "--expect-build-command-line", (Get-RequiredString -Object $invocation -Name "commandLine" -Context "nativeBuild.buildInvocation"),
      "--expect-build-jobs", [string](Get-RequiredProperty -Object $invocation -Name "jobs" -Context "nativeBuild.buildInvocation"),
      "--expect-output-directory", (Get-RequiredString -Object $nativeBuild -Name "outputDirectory" -Context "nativeBuild"),
      "--expect-visual-studio-version", (Get-RequiredString -Object $toolchain -Name "visualStudio" -Context "nativeBuild.toolchain"),
      "--expect-windows-sdk-version", (Get-RequiredString -Object $toolchain -Name "windowsSdk" -Context "nativeBuild.toolchain"),
      "--expect-windows-debugger-version", (Get-RequiredString -Object $toolchain -Name "windowsDebugger" -Context "nativeBuild.toolchain"),
      "--expect-python-version", (Get-RequiredString -Object $toolchain -Name "python" -Context "nativeBuild.toolchain"),
      "--expect-python-cipd-package", (Get-RequiredString -Object $toolchain -Name "pythonCipdPackage" -Context "nativeBuild.toolchain"),
      "--expect-python-cipd-version", (Get-RequiredString -Object $toolchain -Name "pythonCipdVersion" -Context "nativeBuild.toolchain"),
      "--expect-python-cipd-instance", (Get-RequiredString -Object $toolchain -Name "pythonCipdInstance" -Context "nativeBuild.toolchain"),
      "--expect-cipd-client-version", (Get-RequiredString -Object $toolchain -Name "cipdClientVersion" -Context "nativeBuild.toolchain"),
      "--expect-cipd-client-sha256", (Get-RequiredString -Object $toolchain -Name "cipdClientSha256" -Context "nativeBuild.toolchain"),
      "--expect-python-path", (Get-RequiredString -Object $toolchain -Name "pythonPath" -Context "nativeBuild.toolchain"),
      "--expect-python-runtime-tree-sha256", (Get-RequiredString -Object $toolchain -Name "pythonRuntimeTreeSha256" -Context "nativeBuild.toolchain"),
      "--expect-python-sha256", (Get-RequiredString -Object $toolchain -Name "pythonSha256" -Context "nativeBuild.toolchain"),
      "--expect-seven-zip-path", (Get-RequiredString -Object $toolchain -Name "sevenZipPath" -Context "nativeBuild.toolchain"),
      "--expect-seven-zip-sha256", (Get-RequiredString -Object $toolchain -Name "sevenZipSha256" -Context "nativeBuild.toolchain"),
      "--max-files", [string]$MaximumRuntimeFiles,
      "--max-uncompressed-bytes", [string]$MaximumRuntimeBytes,
      "--max-archive-bytes", [string]$MaximumRuntimeArchiveBytes,
      "--require-clean-source"
    )) {
    $verifyArguments.Add([string]$argument)
  }
  $sourceInputs = @(Get-RequiredProperty -Object $patchSet -Name "inputs" `
      -Context "source.patchSet")
  if ($sourceInputs.Count -lt 1) {
    throw "Authenticated runtime manifest has no source inputs."
  }
  foreach ($sourceInput in $sourceInputs) {
    $verifyArguments.Add("--expect-source-input")
    $verifyArguments.Add(
      (Get-RequiredString -Object $sourceInput -Name "path" -Context "source.patchSet.inputs") +
      "=" +
      (Get-RequiredString -Object $sourceInput -Name "sha256" -Context "source.patchSet.inputs")
    )
  }
  [void](Invoke-BoundedProcess -FilePath $pythonSnapshotPath `
      -Arguments $verifyArguments.ToArray() -WorkingDirectory $script:RepoRoot `
      -Description "strict native runtime verification/extraction" -IsolatedPython)
  if ((Get-LowerSha256 -Path $runtimeArchiveTool) -cne $runtimeArchiveToolSha256 -or
      (Get-LowerSha256 -Path $pythonSnapshotPath) -cne $expectedPython -or
      (Get-DirectoryTreeSha256 -Root $pythonSnapshotRoot) -cne
        $expectedPythonRuntimeTree) {
    throw "The runtime verifier changed during verification."
  }
  $verifiedRuntime = Join-Path $extractRoot $archiveRoot
  [void](Get-RegularFile -Path (Join-Path $verifiedRuntime "chrome.exe") `
      -Description "Verified Kwiken chrome.exe")
  [IO.Directory]::Move($verifiedRuntime, (Join-Path $packageRoot "runtime"))

  $webStoreDestination = Join-Path $packageRoot "extensions\chromium-web-store"
  Expand-PinnedWebStoreArchive -ArchivePath $webStoreSnapshot `
    -Destination $webStoreDestination

  $provenanceRoot = Join-Path $packageRoot "provenance"
  [void][IO.Directory]::CreateDirectory($provenanceRoot)
  Copy-Item -LiteralPath $readySnapshot `
    -Destination (Join-Path $provenanceRoot "RELEASE.READY.json") -ErrorAction Stop
  Copy-Item -LiteralPath $manifestSnapshot `
    -Destination (Join-Path $provenanceRoot $expectedManifestName) -ErrorAction Stop
  Copy-Item -LiteralPath (Join-Path $script:ForkRoot "distribution\licenses\chromium.txt") `
    -Destination (Join-Path $packageRoot "LICENSE.chromium.txt") -ErrorAction Stop
  Copy-Item -LiteralPath (Join-Path $script:ForkRoot "distribution\licenses\chromium-web-store.txt") `
    -Destination (Join-Path $packageRoot "LICENSE.chromium-web-store.txt") -ErrorAction Stop
  $notice = @"
Kwiken is an independent Chromium-based browser distribution.

Browser engine: Kwiken's native Chromium $script:Version build.
Runtime provenance: provenance\$expectedManifestName
Authenticated READY SHA-256: $expectedReady

Extension-store compatibility: Chromium Web Store 1.5.5.3 (NeverDecaf).
Source archive SHA-256: $script:ExpectedWebStoreSha256

Kwiken is not affiliated with Google or The Chromium Authors.
Chromium is a trademark of Google LLC.
"@
  [IO.File]::WriteAllText(
    (Join-Path $packageRoot "NOTICE.txt"),
    ($notice.Trim() + "`r`n"),
    [Text.UTF8Encoding]::new($false)
  )

  $iconPath = Join-Path $script:ForkRoot "assets\kwiken.ico"
  [void](Get-RegularFile -Path $iconPath -Description "Kwiken icon")
  $vsEnvironment = Import-VisualStudioEnvironment -WorkDirectory $launcherRoot
  $resourceCompiler = Find-ExecutableInPath -Name "rc.exe" `
    -PathValue ([string]$vsEnvironment["PATH"])
  $compiler = Find-ExecutableInPath -Name "cl.exe" `
    -PathValue ([string]$vsEnvironment["PATH"])
  Copy-Item -LiteralPath $iconPath -Destination (Join-Path $launcherRoot "kwiken.ico") `
    -ErrorAction Stop
  Copy-Item -LiteralPath (Join-Path $script:ForkRoot "distribution\launcher\KwikenLauncher.manifest") `
    -Destination $launcherRoot -ErrorAction Stop
  [void](Invoke-BoundedProcess -FilePath $resourceCompiler -Arguments @(
      "/nologo", "/fo", (Join-Path $launcherRoot "KwikenLauncher.res"),
      (Join-Path $script:ForkRoot "distribution\launcher\KwikenLauncher.rc")
    ) -WorkingDirectory $launcherRoot -Description "Kwiken launcher resources" `
    -EnvironmentVariables $vsEnvironment)
  [void](Invoke-BoundedProcess -FilePath $compiler -Arguments @(
      "/nologo", "/std:c++20", "/O2", "/MT", "/EHsc", "/DUNICODE", "/D_UNICODE", "/W4",
      "/Fe:$(Join-Path $packageRoot 'Kwiken.exe')",
      (Join-Path $script:ForkRoot "distribution\launcher\KwikenLauncher.cpp"),
      (Join-Path $launcherRoot "KwikenLauncher.res"),
      "shell32.lib", "ole32.lib", "propsys.lib", "user32.lib", "uuid.lib",
      "/link", "/SUBSYSTEM:WINDOWS", "/MANIFEST:NO"
    ) -WorkingDirectory $launcherRoot -Description "Kwiken native launcher" `
    -EnvironmentVariables $vsEnvironment)
  [void](Get-RegularFile -Path (Join-Path $packageRoot "Kwiken.exe") `
      -Description "Kwiken launcher")

  $stagedInstaller = Join-Path $publicationRoot `
    "Kwiken-Setup-$script:ReleaseVersion.unsigned.exe"
  [void](Invoke-BoundedProcess -FilePath $makeNsisSnapshotPath -Arguments @(
      "/DVERSION=$script:Version",
      "/DRELEASE_VERSION=$script:ReleaseVersion",
      "/DSTAGING=$packageRoot",
      "/DOUTFILE=$stagedInstaller",
      "/DICON=$iconPath",
      (Join-Path $script:ForkRoot "distribution\installer\Kwiken.nsi")
    ) -WorkingDirectory $script:RepoRoot -Description "Kwiken NSIS installer")
  if ((Get-LowerSha256 -Path $makeNsisSnapshotPath) -cne $expectedMakeNsis -or
      (Get-DirectoryTreeSha256 -Root $makeNsisSnapshotRoot) -cne
        $expectedMakeNsisRuntimeTree) {
    throw "The private NSIS runtime changed while building the installer."
  }
  $installer = Get-RegularFile -Path $stagedInstaller -Description "Kwiken installer"
  if ($installer.Length -lt 1 -or $installer.VersionInfo.ProductName -cne "Kwiken") {
    throw "NSIS did not produce a Kwiken-branded installer."
  }
  $installerSha256 = Get-LowerSha256 -Path $stagedInstaller

  # Reject mutation or replacement of every explicit handoff after the long
  # packaging operations. The installer was made only from private snapshots.
  if ((Get-LowerSha256 -Path $readyInput.FullName) -cne $expectedReady -or
      (Get-LowerSha256 -Path $archiveInput.FullName) -cne $readyArchiveSha256 -or
      (Get-LowerSha256 -Path $manifestInput.FullName) -cne $readyManifestSha256 -or
      (Get-LowerSha256 -Path $webStoreInput.FullName) -cne $script:ExpectedWebStoreSha256 -or
      (Get-LowerSha256 -Path $pythonInput.FullName) -cne $expectedPython -or
      (Get-DirectoryTreeSha256 -Root $pythonRootInput.FullName) -cne
        $expectedPythonRuntimeTree -or
      (Get-LowerSha256 -Path $makeNsisInput.FullName) -cne $expectedMakeNsis -or
      (Get-DirectoryTreeSha256 -Root $makeNsisRootInput.FullName) -cne
        $expectedMakeNsisRuntimeTree -or
      (Get-LowerSha256 -Path $runtimeArchiveToolSource) -cne $runtimeArchiveToolSha256) {
    throw "A distribution input changed while the installer was being built."
  }

  $releaseRoot = Join-Path $script:ForkRoot "release"
  if (-not (Test-Path -LiteralPath $releaseRoot)) {
    [void][IO.Directory]::CreateDirectory($releaseRoot)
  }
  Assert-NoReparsePath -Path $releaseRoot
  $installerPath = Join-Path $releaseRoot "Kwiken-Setup-$script:ReleaseVersion.exe"
  if (Test-Path -LiteralPath $installerPath) {
    throw "Refusing to overwrite the public Kwiken installer: $installerPath"
  }
  $publishTemporary = Join-Path $releaseRoot `
    (".Kwiken-Setup-$script:ReleaseVersion-" + [Guid]::NewGuid().ToString("N") + ".publishing")
  [void](Copy-InputSnapshot -Source $stagedInstaller -Destination $publishTemporary `
      -MaximumBytes ([long]$installer.Length))
  if ((Get-LowerSha256 -Path $publishTemporary) -cne $installerSha256) {
    throw "Published installer staging copy changed before commit."
  }
  [IO.File]::Move($publishTemporary, $installerPath)
  $publishTemporary = $null
  $published = $true
  [pscustomobject]@{
    InstallerPath = $installerPath
    InstallerSha256 = $installerSha256
    ReleaseVersion = $script:ReleaseVersion
    RuntimeReadySha256 = $expectedReady
    RuntimeArchiveSha256 = $readyArchiveSha256
    RuntimeManifestSha256 = $readyManifestSha256
    Signed = $false
  }
} finally {
  if ($null -ne $publishTemporary -and (Test-Path -LiteralPath $publishTemporary)) {
    Remove-Item -LiteralPath $publishTemporary -Force -ErrorAction SilentlyContinue
  }
  try {
    Remove-PrivateDistributionDirectory -Path $workRoot -Parent $cacheRoot
  } catch {
    if ($published) {
      Write-Warning "Private distribution staging cleanup failed: $($_.Exception.Message)"
    } else {
      throw
    }
  }
}
