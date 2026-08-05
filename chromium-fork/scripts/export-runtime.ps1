[CmdletBinding()]
param(
  [string]$ChromiumRoot,
  [string]$DepotToolsRoot,
  [string]$VisualStudioRoot,
  [string]$OutputDirectory,
  [ValidateRange(1, 500)]
  [int]$Jobs = 2,
  [ValidateRange(1, 300)]
  [int]$SmokeTimeoutSeconds = 60
)

. (Join-Path $PSScriptRoot "common.ps1")
. (Join-Path $PSScriptRoot "launch-support.ps1")

$script:ArchiveTimeoutSeconds = 3600
$script:SevenZipTimeoutSeconds = 900
$script:MaximumRuntimeFiles = 10000
$script:MaximumRuntimeBytes = [Int64]4 * 1024 * 1024 * 1024
$script:MaximumRuntimeArchiveBytes = [Int64]5 * 1024 * 1024 * 1024
$script:PinnedSevenZipRelativePath = "third_party/lzma_sdk/bin/host_platform/7za.exe"
$script:ExpectedPeMachine = 0x8664

function Get-LowerSha256 {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Required provenance input was not found: $Path"
  }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Initialize-KwikenPathInterop {
  if ("KwikenFinalPath" -as [type]) {
    return
  }
  Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class KwikenFinalPath {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(
        string name,
        UInt32 access,
        UInt32 share,
        IntPtr securityAttributes,
        UInt32 creationDisposition,
        UInt32 flags,
        IntPtr template);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern UInt32 GetFinalPathNameByHandle(
        SafeFileHandle handle,
        StringBuilder path,
        UInt32 pathLength,
        UInt32 flags);

    public static string Resolve(string path) {
        const UInt32 FILE_SHARE_READ = 1;
        const UInt32 FILE_SHARE_WRITE = 2;
        const UInt32 FILE_SHARE_DELETE = 4;
        const UInt32 OPEN_EXISTING = 3;
        const UInt32 FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        using (SafeFileHandle handle = CreateFile(
            path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero)) {
            if (handle.IsInvalid) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            var buffer = new StringBuilder(1024);
            UInt32 length = GetFinalPathNameByHandle(
                handle, buffer, (UInt32)buffer.Capacity, 0);
            if (length == 0) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            if (length >= buffer.Capacity) {
                buffer.Capacity = checked((int)length + 1);
                length = GetFinalPathNameByHandle(
                    handle, buffer, (UInt32)buffer.Capacity, 0);
                if (length == 0 || length >= buffer.Capacity) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
            string result = buffer.ToString();
            if (result.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) {
                return @"\\" + result.Substring(8);
            }
            if (result.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase)) {
                return result.Substring(4);
            }
            return result;
        }
    }
}
"@
}

function Get-HandleResolvedPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $expanded = [Environment]::ExpandEnvironmentVariables($Path)
  if ($expanded -match '^(?:\\\\\?\\|\\\\\.\\|\\\?\?\\|//[?.]/)') {
    throw "Win32 device-path syntax is not allowed for release paths: $Path"
  }
  $fullPath = [IO.Path]::GetFullPath($expanded)
  $suffix = [Collections.Generic.List[string]]::new()
  $current = $fullPath
  while ($true) {
    try {
      [void](Get-Item -LiteralPath $current -Force -ErrorAction Stop)
      break
    } catch [Management.Automation.ItemNotFoundException] {
      $leaf = Split-Path -Leaf $current
      if (-not $leaf) {
        throw "Could not resolve an existing ancestor for release path: $Path"
      }
      $suffix.Add($leaf)
      $parent = Split-Path -Parent $current
      if (-not $parent -or $parent -eq $current) {
        throw "Could not resolve an existing ancestor for release path: $Path"
      }
      $current = $parent
    } catch {
      throw "Could not safely resolve release path $current`: $($_.Exception.Message)"
    }
  }
  Initialize-KwikenPathInterop
  $resolved = [KwikenFinalPath]::Resolve($current)
  $segments = $suffix.ToArray()
  [Array]::Reverse($segments)
  foreach ($segment in $segments) {
    $resolved = Join-Path $resolved $segment
  }
  return [IO.Path]::GetFullPath($resolved)
}

function Assert-PathOutsideRoot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Root,
    [Parameter(Mandatory = $true)]
    [string]$Description
  )

  $fullPath = (Get-HandleResolvedPath -Path $Path).TrimEnd('\')
  $fullRoot = (Get-HandleResolvedPath -Path $Root).TrimEnd('\')
  $rootPrefix = $fullRoot + '\'
  if ($fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase) -or
      $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "$Description must be outside $fullRoot`: $fullPath"
  }
}

function Assert-NoReparseAncestors {
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
    } catch {
      throw "Could not safely inspect release path $current`: $($_.Exception.Message)"
    }
    if ($null -ne $item -and
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Release paths cannot traverse links or reparse points: $current"
    }
    $parent = Split-Path -Parent $current
    if (-not $parent -or $parent -eq $current) {
      break
    }
    $current = $parent
  }
}

function Assert-NoReparsePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [switch]$Recurse
  )

  Assert-NoReparseAncestors -Path $Path
  $rootItem = Get-Item -LiteralPath $Path -Force
  $pending = [Collections.Generic.Stack[IO.FileSystemInfo]]::new()
  $pending.Push($rootItem)
  while ($pending.Count -gt 0) {
    $item = $pending.Pop()
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Links and reparse points are not allowed in runtime artifacts: $($item.FullName)"
    }
    if ($Recurse -and $item.PSIsContainer) {
      foreach ($child in Get-ChildItem -LiteralPath $item.FullName -Force) {
        $pending.Push($child)
      }
    }
  }
}

function Get-RepositoryRelativePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $repoPrefix = [IO.Path]::GetFullPath($script:RepoRoot).TrimEnd('\') + '\'
  $fullPath = [IO.Path]::GetFullPath($Path)
  if (-not $fullPath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Provenance input is outside the Kwiken repository: $fullPath"
  }
  return $fullPath.Substring($repoPrefix.Length).Replace('\', '/')
}

function Assert-CleanKwikenRepository {
  $changes = @(& git -C $script:RepoRoot status --porcelain=v1 `
      --untracked-files=all --ignore-submodules=none)
  if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect the Kwiken repository state."
  }
  if ($changes.Count -gt 0) {
    throw "Release export requires a clean Kwiken repository: $($changes -join '; ')"
  }
}

function Get-PinnedDepotToolsPython {
  param(
    [Parameter(Mandatory = $true)]
    [string]$DepotToolsRoot
  )

  $bootstrapManifest = Join-Path $DepotToolsRoot "bootstrap\manifest.txt"
  $relativeFile = Join-Path $DepotToolsRoot "python3_bin_reldir.txt"
  if (-not (Test-Path -LiteralPath $bootstrapManifest -PathType Leaf)) {
    throw "Pinned depot_tools Python manifest is missing: $bootstrapManifest"
  }
  if (-not (Test-Path -LiteralPath $relativeFile -PathType Leaf)) {
    throw "depot_tools did not provide python3_bin_reldir.txt. Run bootstrap.ps1."
  }
  Assert-NoReparsePath -Path $relativeFile
  Assert-NoReparsePath -Path $bootstrapManifest
  $bootstrapText = [IO.File]::ReadAllText($bootstrapManifest)
  $pythonManifestMatch = [regex]::Match(
    $bootstrapText,
    '(?m)^infra/3pp/tools/cpython3/\$\{platform\}\s+version:(\S+)\s*$'
  )
  if (-not $pythonManifestMatch.Success) {
    throw "Could not resolve the pinned Python CIPD version from bootstrap/manifest.txt."
  }
  $cipdVersion = $pythonManifestMatch.Groups[1].Value
  $cipdPackage = "infra/3pp/tools/cpython3/windows-amd64"
  $relativeDirectory = [IO.File]::ReadAllText($relativeFile).Trim()
  if (-not $relativeDirectory -or
      $relativeDirectory.IndexOfAny(@([char]10, [char]13, [char]0)) -ge 0 -or
      [IO.Path]::IsPathRooted($relativeDirectory)) {
    throw "depot_tools returned an unsafe Python runtime directory."
  }
  $expectedRelativeDirectory = (
    "bootstrap-" + $cipdVersion.Replace('.', '_') + "_bin\python3\bin"
  )
  if (-not $relativeDirectory.Replace('/', '\').Equals(
      $expectedRelativeDirectory,
      [StringComparison]::Ordinal
    )) {
    throw "depot_tools Python path does not match the pinned CIPD version."
  }
  $depotRoot = [IO.Path]::GetFullPath($DepotToolsRoot).TrimEnd('\')
  $pythonPath = [IO.Path]::GetFullPath(
    (Join-Path (Join-Path $depotRoot $relativeDirectory) "python3.exe")
  )
  if (-not $pythonPath.StartsWith(
      $depotRoot + '\',
      [StringComparison]::OrdinalIgnoreCase
    )) {
    throw "Pinned Python resolved outside depot_tools: $pythonPath"
  }
  if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) {
    throw "Pinned depot_tools python3.exe was not found: $pythonPath"
  }
  Assert-NoReparsePath -Path $pythonPath

  $pythonRuntimeRoot = Split-Path -Parent $pythonPath
  $versionMetadata = Join-Path (Split-Path -Parent $pythonRuntimeRoot) `
    ".versions\cpython3.cipd_version"
  if (-not (Test-Path -LiteralPath $versionMetadata -PathType Leaf) -or
      (Get-Item -LiteralPath $versionMetadata).Length -gt 4096) {
    throw "Pinned Python CIPD instance metadata is missing or oversized."
  }
  Assert-NoReparsePath -Path $versionMetadata
  try {
    $installedVersion = [IO.File]::ReadAllText($versionMetadata) | ConvertFrom-Json
  } catch {
    throw "Could not parse pinned Python CIPD instance metadata: $($_.Exception.Message)"
  }
  $installedInstance = [string]$installedVersion.instance_id
  if ($installedVersion.package_name -cne $cipdPackage -or
      $installedInstance -notmatch '^[A-Za-z0-9_-]{40,64}$') {
    throw "Installed Python CIPD metadata does not identify the pinned package."
  }

  $cipdClientPath = Join-Path $DepotToolsRoot ".cipd_client.exe"
  $cipdDigestPath = Join-Path $DepotToolsRoot "cipd_client_version.digests"
  $cipdVersionPath = Join-Path $DepotToolsRoot "cipd_client_version"
  foreach ($requiredCipdFile in @(
      $cipdClientPath,
      $cipdDigestPath,
      $cipdVersionPath
    )) {
    if (-not (Test-Path -LiteralPath $requiredCipdFile -PathType Leaf)) {
      throw "Pinned CIPD client input is missing: $requiredCipdFile"
    }
    Assert-NoReparsePath -Path $requiredCipdFile
  }
  $digestMatch = [regex]::Match(
    [IO.File]::ReadAllText($cipdDigestPath),
    '(?m)^windows-amd64\s+sha256\s+([0-9a-f]{64})\s*$'
  )
  if (-not $digestMatch.Success) {
    throw "Could not read the pinned windows-amd64 CIPD client digest."
  }
  $cipdClientSha256 = Get-LowerSha256 -Path $cipdClientPath
  if ($cipdClientSha256 -ne $digestMatch.Groups[1].Value) {
    throw "The depot_tools CIPD client does not match its pinned digest."
  }
  $cipdClientVersion = [IO.File]::ReadAllText($cipdVersionPath).Trim()
  if ($cipdClientVersion -notmatch '^git_revision:[0-9a-f]{40}$') {
    throw "The pinned CIPD client version is malformed."
  }
  return [pscustomobject]@{
    Path = $pythonPath
    RuntimeRoot = $pythonRuntimeRoot
    RelativePath = $pythonPath.Substring($depotRoot.Length + 1).Replace('\', '/')
    Sha256 = Get-LowerSha256 -Path $pythonPath
    CipdPackage = $cipdPackage
    CipdVersion = $cipdVersion
    CipdInstance = $installedInstance
    CipdClientVersion = $cipdClientVersion
    CipdClientSha256 = $cipdClientSha256
    CipdClientPath = $cipdClientPath
  }
}

function Initialize-KwikenPrivateDirectoryInterop {
  if ("KwikenPrivateDirectory" -as [type]) {
    return
  }
  Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class KwikenPrivateDirectory {
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

function New-PrivateDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (Test-Path -LiteralPath $Path) {
    throw "Private staging directory already exists: $Path"
  }
  Assert-NoReparseAncestors -Path (Split-Path -Parent $Path)
  $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
  # Chromium's Windows sandbox uses S-1-5-12 as a restricting SID. A
  # restricted token must pass the DACL check both as the current user and as
  # Restricted Code, so this read/execute ACE preserves user isolation while
  # allowing the sandboxed child to map the staged executable and DLLs.
  $restrictedCodeSid = [Security.Principal.SecurityIdentifier]::new("S-1-5-12")
  $sddl = "O:{0}G:{0}D:P(A;OICI;FA;;;{0})(A;OICI;FA;;;SY)(A;OICI;GRGX;;;{1})" -f `
    $currentSid.Value, $restrictedCodeSid.Value
  $created = $false
  try {
    Initialize-KwikenPrivateDirectoryInterop
    [KwikenPrivateDirectory]::Create([IO.Path]::GetFullPath($Path), $sddl)
    $created = $true
    $acl = Get-Acl -LiteralPath $Path
    $actualOwner = $acl.GetOwner([Security.Principal.SecurityIdentifier])
    $restrictedRules = @($acl.GetAccessRules(
        $true,
        $true,
        [Security.Principal.SecurityIdentifier]
      ) | Where-Object {
        $_.IdentityReference -eq $restrictedCodeSid -and
          $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow
      })
    $requiredRights = [Security.AccessControl.FileSystemRights]::ReadAndExecute
    $forbiddenRights = [Security.AccessControl.FileSystemRights]::WriteData -bor
      [Security.AccessControl.FileSystemRights]::AppendData -bor
      [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
      [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
      [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
      [Security.AccessControl.FileSystemRights]::Delete -bor
      [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
      [Security.AccessControl.FileSystemRights]::TakeOwnership
    $expectedInheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
      [Security.AccessControl.InheritanceFlags]::ObjectInherit
    if ($actualOwner -ne $currentSid -or -not $acl.AreAccessRulesProtected -or
        $restrictedRules.Count -ne 1 -or
        ($restrictedRules[0].FileSystemRights -band $requiredRights) -ne
          $requiredRights -or
        ($restrictedRules[0].FileSystemRights -band $forbiddenRights) -ne 0 -or
        $restrictedRules[0].InheritanceFlags -ne $expectedInheritance -or
        $restrictedRules[0].PropagationFlags -ne
          [Security.AccessControl.PropagationFlags]::None) {
      throw "Private staging ACL could not be established for $Path."
    }
  } catch {
    $creationError = $_
    if ($created -and (Test-Path -LiteralPath $Path -PathType Container)) {
      try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
      } catch {
        throw "Private staging setup failed and its directory could not be removed: $Path. Setup error: $($creationError.Exception.Message). Cleanup error: $($_.Exception.Message)"
      }
    }
    throw $creationError
  }
}

function Get-AccessRuleFingerprint {
  param(
    [Parameter(Mandatory = $true)]
    [Security.AccessControl.ObjectSecurity]$Acl
  )

  return @($Acl.GetAccessRules(
      $true,
      $true,
      [Security.Principal.SecurityIdentifier]
    ) | ForEach-Object {
      "{0}|{1}|{2}|{3}|{4}" -f @(
        $_.IdentityReference.Value,
        [int]$_.AccessControlType,
        [int64]$_.FileSystemRights,
        [int]$_.InheritanceFlags,
        [int]$_.PropagationFlags
      )
    } | Sort-Object)
}

function Set-PublicationAclForAtomicMove {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PublicationRoot,
    [Parameter(Mandatory = $true)]
    [string]$DestinationParent
  )

  Assert-NoReparsePath -Path $PublicationRoot -Recurse
  Assert-NoReparsePath -Path $DestinationParent
  $probePath = Join-Path $DestinationParent `
    (".Kwiken-Publication-Acl-" + [Guid]::NewGuid().ToString("N") + ".probe")
  $templateAcl = $null
  try {
    New-Item -ItemType Directory -Path $probePath -ErrorAction Stop | Out-Null
    Assert-NoReparsePath -Path $probePath
    $templateAcl = Get-Acl -LiteralPath $probePath -ErrorAction Stop
  } finally {
    if (Test-Path -LiteralPath $probePath) {
      Remove-Item -LiteralPath $probePath -Force -ErrorAction Stop
    }
  }

  # Same-volume moves retain the source DACL. Convert the ACL that a normal
  # child of DestinationParent inherits into explicit, protected rules before
  # the atomic rename. This makes the release readable by its intended
  # consumers at the instant it becomes visible, without exposing staging.
  $sections = [Security.AccessControl.AccessControlSections]::Access
  $publicationAcl = [Security.AccessControl.DirectorySecurity]::new()
  $publicationAcl.SetSecurityDescriptorSddlForm(
    $templateAcl.GetSecurityDescriptorSddlForm($sections),
    $sections
  )
  $publicationAcl.SetAccessRuleProtection($true, $true)
  Set-Acl -LiteralPath $PublicationRoot -AclObject $publicationAcl -ErrorAction Stop

  $actualAcl = Get-Acl -LiteralPath $PublicationRoot -ErrorAction Stop
  $actualSddl = $actualAcl.GetSecurityDescriptorSddlForm($sections)
  $expectedRules = Get-AccessRuleFingerprint -Acl $publicationAcl
  $actualRules = Get-AccessRuleFingerprint -Acl $actualAcl
  if (-not $actualAcl.AreAccessRulesProtected -or
      (Compare-Object -ReferenceObject $expectedRules -DifferenceObject $actualRules)) {
    throw "The publication directory did not receive the destination ACL."
  }
  foreach ($child in Get-ChildItem -LiteralPath $PublicationRoot -Force -Recurse) {
    $childAcl = Get-Acl -LiteralPath $child.FullName -ErrorAction Stop
    if ($childAcl.AreAccessRulesProtected) {
      throw "A publication child has a protected staging ACL: $($child.FullName)"
    }
  }
  return $actualSddl
}

function Assert-PublicationAclAfterAtomicMove {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PublicationRoot,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedAccessSddl
  )

  $sections = [Security.AccessControl.AccessControlSections]::Access
  $actualAcl = Get-Acl -LiteralPath $PublicationRoot -ErrorAction Stop
  if (-not $actualAcl.AreAccessRulesProtected -or
      $actualAcl.GetSecurityDescriptorSddlForm($sections) -cne $ExpectedAccessSddl) {
    throw "The published release did not retain its reviewed destination ACL."
  }
}

function Remove-ExportStagingDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Parent
  )

  $fullPath = [IO.Path]::GetFullPath($Path)
  $fullParent = [IO.Path]::GetFullPath($Parent)
  $parentRoot = [IO.Path]::GetPathRoot($fullParent)
  if (-not $fullParent.Equals($parentRoot, [StringComparison]::OrdinalIgnoreCase)) {
    $fullParent = $fullParent.TrimEnd('\')
  }
  $actualParent = [IO.Path]::GetFullPath((Split-Path -Parent $fullPath))
  $actualParentRoot = [IO.Path]::GetPathRoot($actualParent)
  if (-not $actualParent.Equals(
      $actualParentRoot,
      [StringComparison]::OrdinalIgnoreCase
    )) {
    $actualParent = $actualParent.TrimEnd('\')
  }
  if (-not $actualParent.Equals(
      $fullParent,
      [StringComparison]::OrdinalIgnoreCase
    ) -or
      (Split-Path -Leaf $fullPath) -notmatch '^\.Kwiken-Runtime-Export-[0-9a-f]{32}\.staging$') {
    throw "Refusing to remove an unexpected release staging directory: $fullPath"
  }
  if (Test-Path -LiteralPath $fullPath) {
    Remove-Item -LiteralPath $fullPath -Recurse -Force -ErrorAction Stop
  }
}

function Initialize-KwikenJobInterop {
  if (("KwikenReleaseJob" -as [type]) -and
      ("KwikenBoundedCapture" -as [type])) {
    return
  }
  Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public static class KwikenReleaseJob {
    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
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
        public UInt64 ReadOperationCount;
        public UInt64 WriteOperationCount;
        public UInt64 OtherOperationCount;
        public UInt64 ReadTransferCount;
        public UInt64 WriteTransferCount;
        public UInt64 OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
        IntPtr job,
        int informationClass,
        IntPtr information,
        UInt32 informationLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    public static IntPtr CreateKillOnClose() {
        const UInt32 JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        const int JobObjectExtendedLimitInformation = 9;
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        var limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        int length = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
        IntPtr buffer = Marshal.AllocHGlobal(length);
        try {
            Marshal.StructureToPtr(limits, buffer, false);
            if (!SetInformationJobObject(
                    job, JobObjectExtendedLimitInformation, buffer, (UInt32)length)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return job;
        } catch {
            CloseHandle(job);
            throw;
        } finally {
            Marshal.FreeHGlobal(buffer);
        }
    }

    public static void Assign(IntPtr job, IntPtr process) {
        if (!AssignProcessToJobObject(job, process)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public static void Close(IntPtr job) {
        if (job != IntPtr.Zero && !CloseHandle(job)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}

public sealed class KwikenBoundedCapture {
    private readonly Stream input;
    private readonly int maximumBytes;
    private readonly MemoryStream content = new MemoryStream();
    private volatile bool limitExceeded;
    private Exception failure;

    private KwikenBoundedCapture(Stream input, int maximumBytes) {
        if (input == null) {
            throw new ArgumentNullException("input");
        }
        if (maximumBytes < 1) {
            throw new ArgumentOutOfRangeException("maximumBytes");
        }
        this.input = input;
        this.maximumBytes = maximumBytes;
        Completion = Task.Factory.StartNew(
            Capture,
            CancellationToken.None,
            TaskCreationOptions.LongRunning,
            TaskScheduler.Default);
    }

    public Task Completion { get; private set; }

    public bool LimitExceeded {
        get { return limitExceeded; }
    }

    public static KwikenBoundedCapture Start(Stream input, int maximumBytes) {
        return new KwikenBoundedCapture(input, maximumBytes);
    }

    private void Capture() {
        byte[] buffer = new byte[8192];
        try {
            while (true) {
                int count = input.Read(buffer, 0, buffer.Length);
                if (count == 0) {
                    return;
                }
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
            throw new InvalidOperationException("Redirected process output exceeded its byte limit.");
        }
        return new UTF8Encoding(false, false).GetString(content.ToArray());
    }
}
"@
}

function Stop-ProcessTreeChecked {
  param(
    [Parameter(Mandatory = $true)]
    [Diagnostics.Process]$Process
  )

  $Process.Refresh()
  if ($Process.HasExited) {
    return
  }
  $taskkillPath = Join-Path $env:SystemRoot "System32\taskkill.exe"
  $taskkillOutput = @(& $taskkillPath /PID ([string]$Process.Id) /T /F 2>&1)
  $taskkillExitCode = $LASTEXITCODE
  [void]$Process.WaitForExit(10000)
  $Process.Refresh()
  # The retained Process object refers to the original process even if its PID
  # has since been reused. Its final exit state is authoritative; taskkill may
  # legitimately return nonzero when the process exits between the first check
  # and the command.
  if (-not $Process.HasExited) {
    throw "Could not terminate process tree $($Process.Id) (taskkill=$taskkillExitCode): $($taskkillOutput -join ' ')"
  }
}

function Invoke-DirectProcess {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [string[]]$Arguments = @(),
    [Parameter(Mandatory = $true)]
    [string]$WorkingDirectory,
    [Parameter(Mandatory = $true)]
    [int]$TimeoutSeconds,
    [Parameter(Mandatory = $true)]
    [string]$Description,
    [switch]$IsolatedPython,
    [switch]$SanitizeCipd,
    [ValidateRange(1, 268435456)]
    [int]$MaximumStandardOutputBytes = 16777216,
    [ValidateRange(1, 268435456)]
    [int]$MaximumStandardErrorBytes = 4194304
  )

  $targetSpec = [ordered]@{
    filePath = $FilePath
    arguments = Join-WindowsCommandLineArguments -Arguments $Arguments
    workingDirectory = $WorkingDirectory
    maximumStandardOutputBytes = $MaximumStandardOutputBytes
    maximumStandardErrorBytes = $MaximumStandardErrorBytes
  }
  $targetSpecBytes = [Text.Encoding]::UTF8.GetBytes(
    ($targetSpec | ConvertTo-Json -Compress)
  )
  $targetSpecBase64 = [Convert]::ToBase64String($targetSpecBytes)
  $launchGateName = "Local\Kwiken-Release-Launch-$([Guid]::NewGuid().ToString('N'))"
  $launchGate = [Threading.EventWaitHandle]::new(
    $false,
    [Threading.EventResetMode]::ManualReset,
    $launchGateName
  )
  $launcherSource = @'
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$InformationPreference = "SilentlyContinue"
$VerbosePreference = "SilentlyContinue"
$DebugPreference = "SilentlyContinue"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

public sealed class KwikenLauncherRelay {
    private readonly Stream input;
    private readonly Stream output;
    private readonly int maximumBytes;
    private volatile bool limitExceeded;
    private Exception failure;

    private KwikenLauncherRelay(Stream input, Stream output, int maximumBytes) {
        this.input = input;
        this.output = output;
        this.maximumBytes = maximumBytes;
        Completion = Task.Factory.StartNew(
            Relay,
            CancellationToken.None,
            TaskCreationOptions.LongRunning,
            TaskScheduler.Default);
    }

    public Task Completion { get; private set; }

    public bool LimitExceeded {
        get { return limitExceeded; }
    }

    public static KwikenLauncherRelay Start(
            Stream input, Stream output, int maximumBytes) {
        if (input == null || output == null) {
            throw new ArgumentNullException();
        }
        if (maximumBytes < 1) {
            throw new ArgumentOutOfRangeException("maximumBytes");
        }
        return new KwikenLauncherRelay(input, output, maximumBytes);
    }

    private void Relay() {
        byte[] buffer = new byte[8192];
        long total = 0;
        try {
            while (true) {
                int count = input.Read(buffer, 0, buffer.Length);
                if (count == 0) {
                    output.Flush();
                    return;
                }
                total += count;
                if (total > maximumBytes) {
                    limitExceeded = true;
                    return;
                }
                output.Write(buffer, 0, count);
                output.Flush();
            }
        } catch (Exception exception) {
            failure = exception;
        }
    }

    public void ThrowIfFailed() {
        if (failure != null) {
            throw new IOException("Could not relay release target output.", failure);
        }
        if (limitExceeded) {
            throw new InvalidOperationException(
                "Release target output exceeded its byte limit.");
        }
    }
}
"@
$gate = $null
try {
  $json = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String($env:KWIKEN_RELEASE_TARGET)
  )
  $spec = $json | ConvertFrom-Json
  $gateName = $env:KWIKEN_RELEASE_GATE
  [Environment]::SetEnvironmentVariable(
    "KWIKEN_RELEASE_TARGET", $null, [EnvironmentVariableTarget]::Process
  )
  [Environment]::SetEnvironmentVariable(
    "KWIKEN_RELEASE_GATE", $null, [EnvironmentVariableTarget]::Process
  )
  $gate = [Threading.EventWaitHandle]::OpenExisting($gateName)
  if (-not $gate.WaitOne(60000)) {
    throw "Release launcher was not admitted to its process job."
  }
  $info = [Diagnostics.ProcessStartInfo]::new()
  $info.FileName = [string]$spec.filePath
  $info.Arguments = [string]$spec.arguments
  $info.WorkingDirectory = [string]$spec.workingDirectory
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $target = [Diagnostics.Process]::new()
  $target.StartInfo = $info
  if (-not $target.Start()) {
    throw "Windows did not return the release target process."
  }
  $stdoutRelay = [KwikenLauncherRelay]::Start(
    $target.StandardOutput.BaseStream,
    [Console]::OpenStandardOutput(),
    [int]$spec.maximumStandardOutputBytes
  )
  $stderrRelay = [KwikenLauncherRelay]::Start(
    $target.StandardError.BaseStream,
    [Console]::OpenStandardError(),
    [int]$spec.maximumStandardErrorBytes
  )
  while (-not $target.HasExited) {
    if ($stdoutRelay.LimitExceeded -or $stderrRelay.LimitExceeded) {
      try { $target.Kill() } catch {}
      throw "Release target output exceeded its byte limit."
    }
    [void]$target.WaitForExit(100)
    $target.Refresh()
  }
  foreach ($relay in @($stdoutRelay, $stderrRelay)) {
    # The outer process owns the single global deadline and kill-on-close job.
    # Waiting here avoids a shorter drain timeout that could reject slow but
    # healthy Chrome shutdown; the outer job still bounds stuck descendants.
    $relay.Completion.Wait()
    $relay.ThrowIfFailed()
  }
  exit $target.ExitCode
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 254
} finally {
  if ($null -ne $gate) {
    $gate.Dispose()
  }
}
'@
  $launcherEncoded = [Convert]::ToBase64String(
    [Text.Encoding]::Unicode.GetBytes($launcherSource)
  )
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = (Get-Process -Id $PID).Path
  $startInfo.Arguments = Join-WindowsCommandLineArguments -Arguments @(
    "-NoLogo",
    "-NoProfile",
    "-NonInteractive",
    "-OutputFormat",
    "Text",
    "-EncodedCommand",
    $launcherEncoded
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
      if ($name.ToString().StartsWith(
          "PYTHON",
          [StringComparison]::OrdinalIgnoreCase
        )) {
        $startInfo.EnvironmentVariables.Remove($name.ToString())
      }
    }
  }
  if ($SanitizeCipd) {
    foreach ($name in @($startInfo.EnvironmentVariables.Keys)) {
      if ($name.ToString().StartsWith(
          "CIPD_",
          [StringComparison]::OrdinalIgnoreCase
        ) -or $name.ToString().StartsWith(
          "LUCI_",
          [StringComparison]::OrdinalIgnoreCase
        )) {
        $startInfo.EnvironmentVariables.Remove($name.ToString())
      }
    }
  }
  $startInfo.EnvironmentVariables["KWIKEN_RELEASE_TARGET"] = $targetSpecBase64
  $startInfo.EnvironmentVariables["KWIKEN_RELEASE_GATE"] = $launchGateName

  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  $started = $false
  $jobHandle = [IntPtr]::Zero
  $stdoutCapture = $null
  $stderrCapture = $null
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  try {
    Initialize-KwikenJobInterop
    $jobHandle = [KwikenReleaseJob]::CreateKillOnClose()
    if (-not $process.Start()) {
      throw "Windows did not return a process for $Description."
    }
    $started = $true
    [KwikenReleaseJob]::Assign($jobHandle, $process.Handle)
    [void]$launchGate.Set()
    $stdoutCapture = [KwikenBoundedCapture]::Start(
      $process.StandardOutput.BaseStream,
      $MaximumStandardOutputBytes
    )
    $stderrCapture = [KwikenBoundedCapture]::Start(
      $process.StandardError.BaseStream,
      $MaximumStandardErrorBytes
    )
    $outputLimit = $null
    while (-not $process.HasExited) {
      if ($stdoutCapture.LimitExceeded) {
        $outputLimit = "standard output"
        break
      }
      if ($stderrCapture.LimitExceeded) {
        $outputLimit = "standard error"
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
    if ($null -ne $outputLimit) {
      [KwikenReleaseJob]::Close($jobHandle)
      $jobHandle = [IntPtr]::Zero
      [void]$process.WaitForExit(10000)
      $process.Refresh()
      if (-not $process.HasExited) {
        Stop-ProcessTreeChecked -Process $process
      }
      throw "$Description exceeded its $outputLimit capture limit; its process job was terminated."
    }
    if (-not $process.HasExited) {
      [KwikenReleaseJob]::Close($jobHandle)
      $jobHandle = [IntPtr]::Zero
      [void]$process.WaitForExit(10000)
      $process.Refresh()
      if (-not $process.HasExited) {
        Stop-ProcessTreeChecked -Process $process
      }
      throw "$Description timed out after $TimeoutSeconds seconds; its process job was terminated."
    }
    $exitCode = $process.ExitCode
    # Closing the kill-on-close job after the main process exits terminates any
    # descendants still holding redirected pipe handles.
    [KwikenReleaseJob]::Close($jobHandle)
    $jobHandle = [IntPtr]::Zero
    foreach ($capture in @($stdoutCapture, $stderrCapture)) {
      $remainingMilliseconds = [Math]::Max(
        1,
        [int][Math]::Floor(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
      )
      if (-not $capture.Completion.Wait($remainingMilliseconds)) {
        throw "$Description did not close redirected output before its deadline."
      }
    }
    if ($stdoutCapture.LimitExceeded) {
      throw "$Description exceeded its standard output capture limit."
    }
    if ($stderrCapture.LimitExceeded) {
      throw "$Description exceeded its standard error capture limit."
    }
    $stdout = $stdoutCapture.GetUtf8Text()
    $stderr = $stderrCapture.GetUtf8Text()
    if ($exitCode -ne 0) {
      throw "$Description failed with exit code $exitCode`: $stderr"
    }
    return [pscustomobject]@{
      StandardOutput = $stdout
      StandardError = $stderr
      ExitCode = $exitCode
    }
  } finally {
    if ($jobHandle -ne [IntPtr]::Zero) {
      [KwikenReleaseJob]::Close($jobHandle)
      $jobHandle = [IntPtr]::Zero
    }
    if ($started -and -not $process.HasExited) {
      Stop-ProcessTreeChecked -Process $process
    }
    $launchGate.Dispose()
    $process.Dispose()
  }
}

function Invoke-PythonRuntimeArchive {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PythonPath,
    [Parameter(Mandatory = $true)]
    [string]$ToolPath,
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,
    [Parameter(Mandatory = $true)]
    [string]$RuntimeRoot,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedExeSha256,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedRuntimeTreeSha256,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedToolSha256
  )

  Assert-PythonSnapshot -PythonPath $PythonPath -RuntimeRoot $RuntimeRoot `
    -ExpectedExeSha256 $ExpectedExeSha256 `
    -ExpectedRuntimeTreeSha256 $ExpectedRuntimeTreeSha256
  if ((Get-LowerSha256 -Path $ToolPath) -ne $ExpectedToolSha256) {
    throw "The private runtime_archive.py snapshot changed before execution."
  }
  $allArguments = @("-I", "-S", "-B", $ToolPath) + $Arguments
  $result = Invoke-DirectProcess -FilePath $PythonPath -Arguments $allArguments `
    -WorkingDirectory $script:RepoRoot -TimeoutSeconds $script:ArchiveTimeoutSeconds `
    -Description "runtime_archive.py" -IsolatedPython
  if ($result.StandardOutput) {
    Write-Verbose $result.StandardOutput.Trim()
  }
}

function Invoke-DependencyStateCapture {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PythonPath,
    [Parameter(Mandatory = $true)]
    [string]$RuntimeRoot,
    [Parameter(Mandatory = $true)]
    [string]$ToolPath,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedExeSha256,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedRuntimeTreeSha256,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedToolSha256,
    [Parameter(Mandatory = $true)]
    [string]$CheckoutRoot,
    [Parameter(Mandatory = $true)]
    [string]$DepotToolsRoot,
    [Parameter(Mandatory = $true)]
    [string]$DepotToolsRevision,
    [Parameter(Mandatory = $true)]
    [string]$SourceDeltaSha256,
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 32)]
    [int]$GclientJobs
  )

  Assert-PythonSnapshot -PythonPath $PythonPath -RuntimeRoot $RuntimeRoot `
    -ExpectedExeSha256 $ExpectedExeSha256 `
    -ExpectedRuntimeTreeSha256 $ExpectedRuntimeTreeSha256
  if ((Get-LowerSha256 -Path $ToolPath) -ne $ExpectedToolSha256) {
    throw "The private dependency_state.py snapshot changed before execution."
  }
  $result = Invoke-DirectProcess -FilePath $PythonPath -Arguments @(
    "-I", "-S", "-B", $ToolPath,
    "--checkout-root", $CheckoutRoot,
    "--depot-tools-root", $DepotToolsRoot,
    "--depot-tools-revision", $DepotToolsRevision,
    "--source-delta-sha256", $SourceDeltaSha256,
    "--gclient-jobs", [string]$GclientJobs
  ) -WorkingDirectory $CheckoutRoot -TimeoutSeconds $script:ArchiveTimeoutSeconds `
    -Description "dependency-state capture" -IsolatedPython
  if ([string]::IsNullOrWhiteSpace($result.StandardOutput)) {
    throw "dependency_state.py returned an empty manifest."
  }
  [IO.File]::WriteAllText(
    $OutputPath,
    $result.StandardOutput,
    [Text.UTF8Encoding]::new($false)
  )
  try {
    $manifest = $result.StandardOutput | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "dependency_state.py returned malformed JSON: $($_.Exception.Message)"
  }
  $treeSha256 = [string]$manifest.treeSha256
  if ($treeSha256 -cnotmatch '^[0-9a-f]{64}$') {
    throw "dependency_state.py returned a malformed dependency tree hash."
  }
  return [pscustomobject]@{
    ManifestSha256 = Get-LowerSha256 -Path $OutputPath
    TreeSha256 = $treeSha256
  }
}

function Get-PythonVersionText {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PythonPath,
    [Parameter(Mandatory = $true)]
    [string]$RuntimeRoot,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedExeSha256,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedRuntimeTreeSha256
  )

  Assert-PythonSnapshot -PythonPath $PythonPath -RuntimeRoot $RuntimeRoot `
    -ExpectedExeSha256 $ExpectedExeSha256 `
    -ExpectedRuntimeTreeSha256 $ExpectedRuntimeTreeSha256
  $result = Invoke-DirectProcess -FilePath $PythonPath `
    -Arguments @("-I", "-S", "-B", "--version") `
    -WorkingDirectory $script:RepoRoot -TimeoutSeconds 30 `
    -Description "pinned depot_tools Python version probe" -IsolatedPython
  $versionText = ($result.StandardOutput + $result.StandardError).Trim()
  if ($versionText -notmatch '^Python \d+\.\d+(?:\.\d+)?$') {
    throw "Pinned Python did not return a recognizable version string: $versionText"
  }
  return $versionText
}

function Copy-FileSnapshot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [Parameter(Mandatory = $true)]
    [string]$Destination
  )

  Assert-NoReparsePath -Path $Source
  if (Test-Path -LiteralPath $Destination) {
    throw "Snapshot destination already exists: $Destination"
  }
  $sourceStream = [IO.File]::Open(
    $Source,
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
      throw "Native build output changed while it was being snapshotted: $Source"
    }
  } finally {
    if ($null -ne $destinationStream) {
      $destinationStream.Dispose()
    }
    $sourceStream.Dispose()
  }
  return Get-LowerSha256 -Path $Destination
}

function Get-DirectoryTreeSha256 {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Root
  )

  Assert-NoReparsePath -Path $Root -Recurse
  $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  $paths = @(
    Get-ChildItem -LiteralPath $fullRoot -File -Recurse -Force |
      ForEach-Object {
        $_.FullName.Substring($fullRoot.Length + 1).Replace('\', '/')
      }
  )
  [Array]::Sort($paths, [StringComparer]::Ordinal)
  $manifest = [IO.MemoryStream]::new()
  $utf8 = [Text.UTF8Encoding]::new($false, $true)
  $sha256 = [Security.Cryptography.SHA256]::Create()
  try {
    foreach ($relativePath in $paths) {
      if ($relativePath.IndexOfAny(@([char]0, [char]10, [char]13)) -ge 0) {
        throw "Unsafe path in snapshotted toolchain: '$relativePath'"
      }
      $filePath = Join-Path $fullRoot $relativePath.Replace('/', '\')
      $file = Get-Item -LiteralPath $filePath -Force
      if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Toolchain snapshots cannot include a reparse point: $filePath"
      }
      $fileHash = Get-LowerSha256 -Path $filePath
      $record = "$relativePath$([char]0)$($file.Length)$([char]0)$fileHash`n"
      $bytes = $utf8.GetBytes($record)
      $manifest.Write($bytes, 0, $bytes.Length)
    }
    $manifest.Position = 0
    $hashBytes = $sha256.ComputeHash($manifest)
    return -join ($hashBytes | ForEach-Object { $_.ToString("x2") })
  } finally {
    $sha256.Dispose()
    $manifest.Dispose()
  }
}

function Assert-InstalledPythonMatchesAuthenticatedRuntime {
  param(
    [Parameter(Mandatory = $true)]
    [string]$InstalledRoot,
    [Parameter(Mandatory = $true)]
    [string]$AuthenticatedRoot
  )

  Assert-NoReparsePath -Path $InstalledRoot -Recurse
  Assert-NoReparsePath -Path $AuthenticatedRoot -Recurse
  $installedFullRoot = [IO.Path]::GetFullPath($InstalledRoot).TrimEnd('\')
  $authenticatedFullRoot = [IO.Path]::GetFullPath(
    $AuthenticatedRoot
  ).TrimEnd('\')
  $authenticatedFiles = [Collections.Generic.Dictionary[string, object]]::new(
    [StringComparer]::Ordinal
  )
  foreach ($file in Get-ChildItem -LiteralPath $authenticatedFullRoot -File `
      -Recurse -Force) {
    $relativePath = $file.FullName.Substring(
      $authenticatedFullRoot.Length + 1
    ).Replace('\', '/')
    if (-not $authenticatedFiles.TryAdd($relativePath, $file)) {
      throw "Authenticated Python runtime contains a duplicate path: $relativePath"
    }
  }
  if ($authenticatedFiles.Count -eq 0) {
    throw "Authenticated Python runtime is empty: $authenticatedFullRoot"
  }

  $verifiedPaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
  )
  foreach ($installedFile in Get-ChildItem -LiteralPath $installedFullRoot -File `
      -Recurse -Force) {
    $relativePath = $installedFile.FullName.Substring(
      $installedFullRoot.Length + 1
    ).Replace('\', '/')
    $authenticatedFile = $null
    if (-not $authenticatedFiles.TryGetValue(
        $relativePath,
        [ref]$authenticatedFile
      )) {
      if ($relativePath -notmatch '(?:^|/)__pycache__/[^/]+\.pyc$') {
        throw "Installed depot_tools Python has an unauthenticated file: $relativePath"
      }
      continue
    }
    if ($installedFile.Length -ne $authenticatedFile.Length -or
        (Get-LowerSha256 -Path $installedFile.FullName) -ne
          (Get-LowerSha256 -Path $authenticatedFile.FullName)) {
      throw "Installed depot_tools Python file differs from CIPD: $relativePath"
    }
    [void]$verifiedPaths.Add($relativePath)
  }
  if ($verifiedPaths.Count -ne $authenticatedFiles.Count) {
    $missing = @($authenticatedFiles.Keys | Where-Object {
        -not $verifiedPaths.Contains($_)
      } | Sort-Object)
    throw "Installed depot_tools Python is missing authenticated files: $($missing -join ', ')"
  }
}

function Copy-DirectorySnapshot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [Parameter(Mandatory = $true)]
    [string]$Destination
  )

  Assert-NoReparsePath -Path $Source -Recurse
  if (Test-Path -LiteralPath $Destination) {
    throw "Snapshot destination already exists: $Destination"
  }
  $sourceRoot = [IO.Path]::GetFullPath($Source).TrimEnd('\')
  New-Item -ItemType Directory -Path $Destination -ErrorAction Stop | Out-Null
  foreach ($item in Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force |
      Sort-Object FullName) {
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Toolchain snapshots cannot include a reparse point: $($item.FullName)"
    }
    $relativePath = $item.FullName.Substring($sourceRoot.Length + 1)
    $target = Join-Path $Destination $relativePath
    if ($item.PSIsContainer) {
      New-Item -ItemType Directory -Path $target -ErrorAction Stop | Out-Null
    } else {
      $targetParent = Split-Path -Parent $target
      if (-not (Test-Path -LiteralPath $targetParent -PathType Container)) {
        New-Item -ItemType Directory -Path $targetParent -Force -ErrorAction Stop |
          Out-Null
      }
      [void](Copy-FileSnapshot -Source $item.FullName -Destination $target)
    }
  }
  $snapshotHash = Get-DirectoryTreeSha256 -Root $Destination
  $sourceHash = Get-DirectoryTreeSha256 -Root $Source
  if ($snapshotHash -ne $sourceHash) {
    throw "Pinned Python runtime changed while it was being snapshotted."
  }
  return $snapshotHash
}

function Assert-PythonSnapshot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PythonPath,
    [Parameter(Mandatory = $true)]
    [string]$RuntimeRoot,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedExeSha256,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedRuntimeTreeSha256
  )

  if ((Get-LowerSha256 -Path $PythonPath) -ne $ExpectedExeSha256 -or
      (Get-DirectoryTreeSha256 -Root $RuntimeRoot) -ne $ExpectedRuntimeTreeSha256) {
    throw "The private pinned Python snapshot changed before execution."
  }
}

function Test-SafeWindowsArchivePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (-not $Path -or $Path.IndexOf([char]0) -ge 0 -or
      $Path.StartsWith('\') -or $Path.StartsWith('/') -or
      $Path -match '^[A-Za-z]:') {
    throw "Unsafe path in Chromium chrome.7z: '$Path'"
  }
  $normalized = $Path.Replace('\', '/')
  $parts = @($normalized.Split('/'))
  $reserved = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
  )
  foreach ($name in @("CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$")) {
    [void]$reserved.Add($name)
  }
  foreach ($number in 1..9) {
    [void]$reserved.Add("COM$number")
    [void]$reserved.Add("LPT$number")
  }
  foreach ($number in @([char]0x00b9, [char]0x00b2, [char]0x00b3)) {
    [void]$reserved.Add("COM$number")
    [void]$reserved.Add("LPT$number")
  }
  foreach ($part in $parts) {
    if (-not $part -or $part -eq '.' -or $part -eq '..' -or
        $part.EndsWith(' ') -or $part.EndsWith('.') -or
        $part.IndexOfAny('<>:"|?*'.ToCharArray()) -ge 0) {
      throw "Unsafe path component in Chromium chrome.7z: '$Path'"
    }
    foreach ($character in $part.ToCharArray()) {
      if ([int]$character -lt 32) {
        throw "Control character in Chromium chrome.7z path: '$Path'"
      }
    }
    $baseName = $part.Split('.')[0]
    if ($reserved.Contains($baseName)) {
      throw "Windows device name in Chromium chrome.7z path: '$Path'"
    }
  }
  if ($parts[0] -cne "Chrome-bin") {
    throw "Chromium chrome.7z entry is outside Chrome-bin: '$Path'"
  }
  return $normalized
}

function Assert-SafeSevenZipListing {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Listing
  )

  $records = [Collections.Generic.List[hashtable]]::new()
  $current = @{}
  $insideEntries = $false
  foreach ($line in ($Listing -split "`r?`n")) {
    if ($line -eq "----------") {
      $insideEntries = $true
      continue
    }
    if (-not $insideEntries) {
      continue
    }
    if (-not $line) {
      if ($current.ContainsKey("Path")) {
        $records.Add($current)
      }
      $current = @{}
      continue
    }
    $separator = $line.IndexOf(" = ", [StringComparison]::Ordinal)
    if ($separator -lt 1) {
      throw "Could not safely parse Chromium chrome.7z technical listing: '$line'"
    }
    $key = $line.Substring(0, $separator)
    $value = $line.Substring($separator + 3)
    if ($current.ContainsKey($key)) {
      throw "Duplicate property '$key' in Chromium chrome.7z listing."
    }
    $current[$key] = $value
  }
  if ($current.ContainsKey("Path")) {
    $records.Add($current)
  }
  if ($records.Count -lt 1 -or $records.Count -gt $script:MaximumRuntimeFiles) {
    throw "Chromium chrome.7z has an invalid entry count: $($records.Count)"
  }

  $paths = [Collections.Generic.Dictionary[string,string]]::new(
    [StringComparer]::OrdinalIgnoreCase
  )
  $filePaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
  )
  $directoryPaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
  )
  [Int64]$totalBytes = 0
  foreach ($record in $records) {
    $rawPath = [string]$record["Path"]
    $path = Test-SafeWindowsArchivePath -Path $rawPath
    if ($paths.ContainsKey($path)) {
      throw "Case-insensitive duplicate in Chromium chrome.7z: '$path' and '$($paths[$path])'"
    }
    $paths[$path] = $rawPath
    if ($record.ContainsKey("Encrypted") -and $record["Encrypted"] -ne "-") {
      throw "Encrypted entries are not allowed in Chromium chrome.7z: '$rawPath'"
    }
    foreach ($linkProperty in @("Symbolic Link", "Hard Link")) {
      if ($record.ContainsKey($linkProperty) -and $record[$linkProperty]) {
        throw "$linkProperty entries are not allowed in Chromium chrome.7z: '$rawPath'"
      }
    }
    $directoryClassifications = [Collections.Generic.List[bool]]::new()
    if ($record.ContainsKey("Folder")) {
      if ($record["Folder"] -notin @("+", "-")) {
        throw "Invalid Folder property in Chromium chrome.7z: '$rawPath'"
      }
      $directoryClassifications.Add($record["Folder"] -eq "+")
    }
    if ($record.ContainsKey("Attributes")) {
      $attributes = [string]$record["Attributes"]
      if ($attributes -cnotmatch '^[DRHSA]+$') {
        throw "Invalid Attributes property in Chromium chrome.7z: '$rawPath'"
      }
      $directoryClassifications.Add($attributes.Contains('D'))
    }
    if ($directoryClassifications.Count -lt 1) {
      throw "Missing directory metadata in Chromium chrome.7z: '$rawPath'"
    }
    $isDirectory = $directoryClassifications[0]
    if (@($directoryClassifications | Where-Object { $_ -ne $isDirectory }).Count -gt 0) {
      throw "Conflicting directory metadata in Chromium chrome.7z: '$rawPath'"
    }
    if ($isDirectory) {
      [void]$directoryPaths.Add($path)
    } else {
      [void]$filePaths.Add($path)
      [Int64]$size = 0
      if (-not $record.ContainsKey("Size") -or
          -not [Int64]::TryParse([string]$record["Size"], [ref]$size) -or
          $size -lt 0) {
        throw "Invalid entry size in Chromium chrome.7z: '$rawPath'"
      }
      $totalBytes += $size
      if ($totalBytes -gt $script:MaximumRuntimeBytes) {
        throw "Chromium chrome.7z exceeds the runtime extraction size limit."
      }
    }

    $parts = @($path.Split('/'))
    if ($parts.Count -gt 1 -and $parts[1] -match '^\d+\.\d+\.\d+\.\d+$' -and
        $parts[1] -ne $script:Version) {
      throw "Chromium chrome.7z contains unexpected version directory '$($parts[1])'."
    }
    for ($index = 1; $index -lt $parts.Count; $index++) {
      $parent = ($parts[0..($index - 1)] -join '/')
      if ($filePaths.Contains($parent)) {
        throw "Chromium chrome.7z treats file '$parent' as a directory."
      }
    }
  }
  foreach ($filePath in $filePaths) {
    if ($directoryPaths.Contains($filePath)) {
      throw "Chromium chrome.7z path is both a file and directory: '$filePath'"
    }
  }
  foreach ($path in $paths.Keys) {
    $parts = @($path.Split('/'))
    for ($index = 1; $index -lt $parts.Count; $index++) {
      $parent = ($parts[0..($index - 1)] -join '/')
      if ($filePaths.Contains($parent)) {
        throw "Chromium chrome.7z treats file '$parent' as a directory."
      }
    }
  }
}

function Invoke-HardenedSevenZipExtraction {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SevenZipPath,
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,
    [Parameter(Mandatory = $true)]
    [string]$Destination,
    [Parameter(Mandatory = $true)]
    [string]$WorkingDirectory
  )

  [void](Invoke-DirectProcess -FilePath $SevenZipPath `
      -Arguments @("t", "-bd", "-p-", "--", $ArchivePath) `
      -WorkingDirectory $WorkingDirectory -TimeoutSeconds $script:SevenZipTimeoutSeconds `
      -Description "Chromium chrome.7z integrity test")
  $listing = Invoke-DirectProcess -FilePath $SevenZipPath `
    -Arguments @("l", "-slt", "-sccUTF-8", "-p-", "--", $ArchivePath) `
    -WorkingDirectory $WorkingDirectory -TimeoutSeconds $script:SevenZipTimeoutSeconds `
    -Description "Chromium chrome.7z listing" `
    -MaximumStandardOutputBytes 16777216 -MaximumStandardErrorBytes 1048576
  Assert-SafeSevenZipListing -Listing $listing.StandardOutput
  New-Item -ItemType Directory -Path $Destination -ErrorAction Stop | Out-Null
  [void](Invoke-DirectProcess -FilePath $SevenZipPath `
      -Arguments @("x", "-bd", "-y", "-p-", "-o$Destination", "--", $ArchivePath) `
      -WorkingDirectory $WorkingDirectory -TimeoutSeconds $script:SevenZipTimeoutSeconds `
      -Description "Chromium chrome.7z extraction")
}

function Get-PeMachine {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  $reader = [IO.BinaryReader]::new($stream)
  try {
    if ($stream.Length -lt 70 -or $reader.ReadUInt16() -ne 0x5a4d) {
      throw "File is not a valid PE image: $Path"
    }
    $stream.Position = 0x3c
    $headerOffset = $reader.ReadUInt32()
    if ($headerOffset -gt ($stream.Length - 6)) {
      throw "PE header is outside the file: $Path"
    }
    $stream.Position = $headerOffset
    if ($reader.ReadUInt32() -ne 0x00004550) {
      throw "File has an invalid PE signature: $Path"
    }
    return $reader.ReadUInt16()
  } finally {
    $reader.Dispose()
    $stream.Dispose()
  }
}

function Assert-Amd64Pe {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Description
  )

  $machine = Get-PeMachine -Path $Path
  if ($machine -ne $script:ExpectedPeMachine) {
    throw "$Description has PE machine 0x$($machine.ToString('x4')); expected AMD64 (0x8664)."
  }
}

function Assert-KwikenPeIdentity {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Description,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedProductName,
    [switch]$RequireVersion
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Description is missing: $Path"
  }
  $versionInfo = (Get-Item -LiteralPath $Path).VersionInfo
  if (-not [string]::Equals(
      $versionInfo.ProductName,
      $ExpectedProductName,
      [StringComparison]::Ordinal
    )) {
    throw "$Description has ProductName '$($versionInfo.ProductName)'; expected '$ExpectedProductName'."
  }
  if ($RequireVersion) {
    $fileVersion = "{0}.{1}.{2}.{3}" -f @(
      $versionInfo.FileMajorPart,
      $versionInfo.FileMinorPart,
      $versionInfo.FileBuildPart,
      $versionInfo.FilePrivatePart
    )
    if ($fileVersion -ne $script:Version) {
      throw "$Description reports FileVersion $fileVersion; expected $script:Version."
    }
  }
}

function Get-ProfileProcesses {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ProfileRoot
  )

  $needle = "--user-data-dir=$ProfileRoot"
  return @(Get-CimInstance -ClassName Win32_Process -OperationTimeoutSec 10 `
      -ErrorAction Stop | Where-Object {
    $_.CommandLine -and $_.CommandLine.IndexOf(
      $needle,
      [StringComparison]::OrdinalIgnoreCase
    ) -ge 0
  })
}

function Test-SameProfileProcess {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Candidate,
    [Parameter(Mandatory = $true)]
    [object]$Current,
    [Parameter(Mandatory = $true)]
    [string]$ProfileRoot
  )

  $needle = "--user-data-dir=$ProfileRoot"
  return $Current.CommandLine -and
    [UInt32]$Current.ProcessId -eq [UInt32]$Candidate.ProcessId -and
    $Current.CreationDate -eq $Candidate.CreationDate -and
    [UInt32]$Current.ParentProcessId -eq [UInt32]$Candidate.ParentProcessId -and
    [string]::Equals(
      [string]$Current.Name,
      [string]$Candidate.Name,
      [StringComparison]::OrdinalIgnoreCase
    ) -and
    [string]::Equals(
      [string]$Current.ExecutablePath,
      [string]$Candidate.ExecutablePath,
      [StringComparison]::OrdinalIgnoreCase
    ) -and
    [string]::Equals(
      [string]$Current.CommandLine,
      [string]$Candidate.CommandLine,
      [StringComparison]::Ordinal
    ) -and
    $Current.CommandLine.IndexOf(
      $needle,
      [StringComparison]::OrdinalIgnoreCase
    ) -ge 0
}

function Stop-ProfileProcessesChecked {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ProfileRoot
  )

  $taskkillPath = Join-Path $env:SystemRoot "System32\taskkill.exe"
  foreach ($candidate in @(Get-ProfileProcesses -ProfileRoot $ProfileRoot)) {
    $candidateId = [UInt32]$candidate.ProcessId
    $current = @(Get-CimInstance -ClassName Win32_Process `
        -Filter "ProcessId = $candidateId" -OperationTimeoutSec 10 `
        -ErrorAction Stop)
    if ($current.Count -eq 0) {
      continue
    }
    if (-not (Test-SameProfileProcess -Candidate $candidate `
        -Current $current[0] -ProfileRoot $ProfileRoot)) {
      # The original process exited or its PID was already reused before this
      # identity check, so it is no longer a cleanup target.
      continue
    }
    # Re-query immediately before the numeric tree-kill operation to minimize
    # the unavoidable PID-only check/use interval in taskkill.exe.
    $confirmed = @(Get-CimInstance -ClassName Win32_Process `
        -Filter "ProcessId = $candidateId" -OperationTimeoutSec 10 `
        -ErrorAction Stop)
    if ($confirmed.Count -eq 0 -or
        -not (Test-SameProfileProcess -Candidate $candidate `
          -Current $confirmed[0] -ProfileRoot $ProfileRoot)) {
      continue
    }
    $output = @(& $taskkillPath /PID ([string]$candidate.ProcessId) /T /F 2>&1)
    $taskkillExitCode = $LASTEXITCODE
    if ($taskkillExitCode -ne 0) {
      $after = @(Get-CimInstance -ClassName Win32_Process `
          -Filter "ProcessId = $candidateId" -OperationTimeoutSec 10 `
          -ErrorAction Stop)
      $sameProcessRemains = $after.Count -gt 0 -and
        (Test-SameProfileProcess -Candidate $candidate `
          -Current $after[0] -ProfileRoot $ProfileRoot)
      if ($sameProcessRemains) {
        throw "Could not terminate smoke-test process tree $candidateId`: $($output -join ' ')"
      }
    }
  }
  $remaining = @(Get-ProfileProcesses -ProfileRoot $ProfileRoot)
  if ($remaining.Count -gt 0) {
    throw "Smoke-test process cleanup was incomplete: $($remaining.ProcessId -join ', ')"
  }
}

function Invoke-RuntimeSmokeTest {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RuntimeRoot,
    [Parameter(Mandatory = $true)]
    [string]$TemporaryRoot
  )

  New-Item -ItemType Directory -Path $TemporaryRoot -ErrorAction Stop | Out-Null
  $browserPath = Join-Path $RuntimeRoot "chrome.exe"
  $profileRoot = Join-Path $TemporaryRoot "smoke-profile"
  $probePath = Join-Path $TemporaryRoot "runtime-smoke.html"
  $marker = "kwiken-runtime-smoke-$([Guid]::NewGuid().ToString('N'))"
  [IO.File]::WriteAllText(
    $probePath,
    "<!doctype html><title>Kwiken smoke</title><main>$marker</main>",
    [Text.UTF8Encoding]::new($false)
  )
  $arguments = @(
    "--headless=new",
    "--disable-gpu",
    "--disable-extensions",
    "--no-first-run",
    "--no-default-browser-check",
    "--user-data-dir=$profileRoot",
    "--dump-dom",
    ([Uri]::new($probePath).AbsoluteUri)
  )
  $smokeFailure = $null
  $cleanupFailure = $null
  try {
    $result = Invoke-DirectProcess -FilePath $browserPath -Arguments $arguments `
      -WorkingDirectory $RuntimeRoot -TimeoutSeconds $SmokeTimeoutSeconds `
      -Description "Kwiken headless runtime smoke test"
    if ($result.StandardOutput -notmatch [regex]::Escape($marker)) {
      throw "Kwiken's headless runtime smoke test did not render the expected marker."
    }
  } catch {
    $smokeFailure = $_
  } finally {
    try {
      Stop-ProfileProcessesChecked -ProfileRoot $profileRoot
    } catch {
      $cleanupFailure = $_
    }
  }
  if ($null -ne $smokeFailure -and $null -ne $cleanupFailure) {
    throw "Runtime smoke test failed: $($smokeFailure.Exception.Message) Cleanup also failed: $($cleanupFailure.Exception.Message)"
  }
  if ($null -ne $smokeFailure) {
    throw $smokeFailure
  }
  if ($null -ne $cleanupFailure) {
    throw $cleanupFailure
  }
}

$ChromiumRoot = Resolve-KwikenBuildRoot -Value $ChromiumRoot `
  -DefaultValue (Get-DefaultChromiumRoot) -Name "ChromiumRoot"
$DepotToolsRoot = Resolve-KwikenBuildRoot -Value $DepotToolsRoot `
  -DefaultValue (Get-DefaultDepotToolsRoot) -Name "DepotToolsRoot"
Assert-DistinctBuildRoots -ChromiumRoot $ChromiumRoot -DepotToolsRoot $DepotToolsRoot

$preflightParameters = @{
  ChromiumRoot = $ChromiumRoot
  DepotToolsRoot = $DepotToolsRoot
  VisualStudioRoot = $VisualStudioRoot
  MinimumFreeSpaceGB = 5
  RequireDepotTools = $true
}
Assert-ChromiumBuildPrerequisites @preflightParameters | Out-Null
$sourceRoot = Assert-ChromiumCheckout -ChromiumRoot $ChromiumRoot
Assert-DepotToolsCheckout -DepotToolsRoot $DepotToolsRoot
Assert-CleanKwikenRepository
$sourceDeltaSha256 = Assert-KwikenSourceDelta -SourceRoot $sourceRoot

$patchRoot = Join-Path $script:ForkRoot "patches"
$patchPaths = @(Get-ChildItem -LiteralPath $patchRoot -Filter "*.patch" -File |
    Sort-Object -Property Name)
if ($patchPaths.Count -eq 0) {
  throw "No reviewed Kwiken source patches were found in $patchRoot."
}
foreach ($patch in $patchPaths) {
  Assert-NoReparsePath -Path $patch.FullName
}
$repositoryRevision = (& git -C $script:RepoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $repositoryRevision -notmatch '^[0-9a-f]{40}$') {
  throw "Could not resolve the Kwiken repository revision."
}

$runtimeArchiveTool = Join-Path $script:ForkRoot "distribution\runtime_archive.py"
if (-not (Test-Path -LiteralPath $runtimeArchiveTool -PathType Leaf)) {
  throw "Runtime archive tool was not found: $runtimeArchiveTool"
}
$dependencyStateTool = Join-Path $script:ForkRoot "scripts\dependency_state.py"
if (-not (Test-Path -LiteralPath $dependencyStateTool -PathType Leaf)) {
  throw "Dependency-state tool was not found: $dependencyStateTool"
}
$python = Get-PinnedDepotToolsPython -DepotToolsRoot $DepotToolsRoot
$sevenZipPath = Join-Path $sourceRoot $script:PinnedSevenZipRelativePath.Replace('/', '\')
if (-not (Test-Path -LiteralPath $sevenZipPath -PathType Leaf)) {
  throw "Chromium's pinned 7za.exe was not found: $sevenZipPath"
}
Assert-NoReparsePath -Path $sevenZipPath
$sevenZipSha256 = Get-LowerSha256 -Path $sevenZipPath

$resolvedVisualStudioRoot = Resolve-VisualStudioRoot -VisualStudioRoot $VisualStudioRoot
$visualStudioInstallation = @(Get-QualifyingVisualStudioInstallations) |
  Where-Object {
    ([IO.Path]::GetFullPath($_.installationPath)).TrimEnd('\').Equals(
      $resolvedVisualStudioRoot,
      [StringComparison]::OrdinalIgnoreCase
    )
  } |
  Sort-Object { [Version]$_.installationVersion } -Descending |
  Select-Object -First 1
if (-not $visualStudioInstallation) {
  throw "Could not read the Visual Studio version at $resolvedVisualStudioRoot."
}
$visualStudioVersion = [string]$visualStudioInstallation.installationVersion
$sdkVersion = Get-ProductVersion -Path (Get-WindowsSdkRcPath)
$debuggerVersion = Get-ProductVersion -Path (Get-WindowsDebuggerPath)
if ($null -eq $sdkVersion -or $null -eq $debuggerVersion) {
  throw "Could not read the validated Windows SDK toolchain versions."
}

$outputRoot = Join-Path $sourceRoot "out\Kwiken"
$rawArchive = Join-Path $outputRoot "chrome.7z"
$miniInstaller = Join-Path $outputRoot "mini_installer.exe"
$outputChrome = Join-Path $outputRoot "chrome.exe"
$outputArgsPath = Join-Path $outputRoot "args.gn"
$repoArgsPath = Join-Path $script:ForkRoot "args.gn"
if (-not (Test-Path -LiteralPath $outputArgsPath -PathType Leaf)) {
  throw "out\Kwiken\args.gn is missing. Run build.ps1 before export-runtime.ps1."
}
$gnArgsSha256 = Get-LowerSha256 -Path $repoArgsPath
if ((Get-LowerSha256 -Path $outputArgsPath) -ne $gnArgsSha256) {
  throw "out\Kwiken\args.gn does not match the reviewed Kwiken build configuration."
}

$buildArguments = @("-C", "out/Kwiken", "chrome", "mini_installer", "-j", [string]$Jobs)
$buildCommandLine = "autoninja -C out/Kwiken chrome mini_installer -j $Jobs"
$buildPythonCachePrefix = Join-Path ([IO.Path]::GetTempPath()) `
  ("Kwiken-Python-Cache-" + [Guid]::NewGuid().ToString("N"))
if (Test-Path -LiteralPath $buildPythonCachePrefix) {
  throw "Refusing to reuse build Python cache prefix: $buildPythonCachePrefix"
}
Assert-PathOutsideRoot -Path $buildPythonCachePrefix -Root $ChromiumRoot `
  -Description "Build Python cache prefix"
Assert-PathOutsideRoot -Path $buildPythonCachePrefix -Root $DepotToolsRoot `
  -Description "Build Python cache prefix"
$environmentSnapshot = New-ChromiumBuildEnvironmentSnapshot
$sanitizedBuildEnvironment = @{}
foreach ($name in @([Environment]::GetEnvironmentVariables(
      [EnvironmentVariableTarget]::Process
    ).Keys)) {
  $nameText = $name.ToString()
  if ($nameText.StartsWith("PYTHON", [StringComparison]::OrdinalIgnoreCase) -or
      $nameText.StartsWith("CIPD_", [StringComparison]::OrdinalIgnoreCase) -or
      $nameText.StartsWith("LUCI_", [StringComparison]::OrdinalIgnoreCase)) {
    $sanitizedBuildEnvironment[$nameText] = [Environment]::GetEnvironmentVariable(
      $nameText,
      [EnvironmentVariableTarget]::Process
    )
    [Environment]::SetEnvironmentVariable(
      $nameText,
      $null,
      [EnvironmentVariableTarget]::Process
    )
  }
}
try {
  Set-ChromiumBuildEnvironment -DepotToolsRoot $DepotToolsRoot `
    -VisualStudioRoot $resolvedVisualStudioRoot
  [Environment]::SetEnvironmentVariable(
    "PYTHONDONTWRITEBYTECODE",
    "1",
    [EnvironmentVariableTarget]::Process
  )
  [Environment]::SetEnvironmentVariable(
    "PYTHONPYCACHEPREFIX",
    $buildPythonCachePrefix,
    [EnvironmentVariableTarget]::Process
  )
  Push-Location $sourceRoot
  try {
    Invoke-BatchFile -Path (Join-Path $DepotToolsRoot "autoninja.bat") `
      -Arguments $buildArguments
  } finally {
    Pop-Location
  }
} finally {
  foreach ($name in @("PYTHONDONTWRITEBYTECODE", "PYTHONPYCACHEPREFIX")) {
    [Environment]::SetEnvironmentVariable(
      $name,
      $null,
      [EnvironmentVariableTarget]::Process
    )
  }
  Restore-ChromiumBuildEnvironment -Snapshot $environmentSnapshot
  foreach ($entry in $sanitizedBuildEnvironment.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable(
      $entry.Key,
      $entry.Value,
      [EnvironmentVariableTarget]::Process
    )
  }
}
if (Test-Path -LiteralPath $buildPythonCachePrefix) {
  throw "The isolated build unexpectedly wrote Python bytecode: $buildPythonCachePrefix"
}

Assert-CleanKwikenRepository
$sourceDeltaSha256AfterBuild = Assert-KwikenSourceDelta -SourceRoot $sourceRoot
if ($sourceDeltaSha256AfterBuild -ne $sourceDeltaSha256) {
  throw "The reviewed Chromium source delta changed during the incremental build."
}
foreach ($requiredOutput in @($rawArchive, $miniInstaller, $outputChrome, $outputArgsPath)) {
  if (-not (Test-Path -LiteralPath $requiredOutput -PathType Leaf)) {
    throw "The incremental native build did not produce required output: $requiredOutput"
  }
}

if (-not $OutputDirectory) {
  $OutputDirectory = Join-Path $script:ForkRoot "release\runtime"
}
$OutputDirectory = [IO.Path]::GetFullPath(
  [Environment]::ExpandEnvironmentVariables($OutputDirectory)
)
Assert-PathOutsideRoot -Path $OutputDirectory -Root $ChromiumRoot `
  -Description "Runtime export directory"
Assert-PathOutsideRoot -Path $OutputDirectory -Root $DepotToolsRoot `
  -Description "Runtime export directory"
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
Assert-NoReparsePath -Path $OutputDirectory

$archiveRootName = "Kwiken-runtime-$script:ReleaseVersion"
$publicationName = "$archiveRootName-windows-x64"
$finalDirectory = Join-Path $OutputDirectory $publicationName
if (Get-Item -LiteralPath $finalDirectory -Force -ErrorAction SilentlyContinue) {
  throw "Refusing to overwrite existing runtime release: $finalDirectory"
}
$stagingRoot = Join-Path $OutputDirectory `
  (".Kwiken-Runtime-Export-" + [Guid]::NewGuid().ToString("N") + ".staging")
New-PrivateDirectory -Path $stagingRoot
$published = $false
$exportFailure = $null
$releaseResult = $null
try {
  $snapshotRoot = Join-Path $stagingRoot "native-snapshots"
  $publicationRoot = Join-Path $stagingRoot "publication"
  New-Item -ItemType Directory -Path $snapshotRoot -ErrorAction Stop | Out-Null
  New-Item -ItemType Directory -Path $publicationRoot -ErrorAction Stop | Out-Null

  $snapshotArchive = Join-Path $snapshotRoot "chrome.7z"
  $snapshotInstaller = Join-Path $snapshotRoot "mini_installer.exe"
  $snapshotChrome = Join-Path $snapshotRoot "chrome.exe"
  $snapshotArgs = Join-Path $snapshotRoot "args.gn"
  $snapshotSevenZip = Join-Path $snapshotRoot "7za.exe"
  $snapshotCipdClient = Join-Path $snapshotRoot "cipd_client.exe"
  $pythonExportRoot = Join-Path $snapshotRoot "authenticated-python"
  $pythonEnsureFile = Join-Path $snapshotRoot "python.ensure"
  $snapshotRuntimeArchiveTool = Join-Path $snapshotRoot "runtime_archive.py"
  $snapshotDependencyStateTool = Join-Path $snapshotRoot "dependency_state.py"
  $snapshotDependencyStateManifest = Join-Path $snapshotRoot "dependency-state.json"
  $chrome7zSha256 = Copy-FileSnapshot -Source $rawArchive -Destination $snapshotArchive
  $miniInstallerSha256 = Copy-FileSnapshot -Source $miniInstaller -Destination $snapshotInstaller
  $chromeExeSha256 = Copy-FileSnapshot -Source $outputChrome -Destination $snapshotChrome
  $snapshotArgsSha256 = Copy-FileSnapshot -Source $outputArgsPath -Destination $snapshotArgs
  $snapshotSevenZipSha256 = Copy-FileSnapshot -Source $sevenZipPath `
    -Destination $snapshotSevenZip
  $snapshotCipdClientSha256 = Copy-FileSnapshot -Source $python.CipdClientPath `
    -Destination $snapshotCipdClient
  if ($snapshotCipdClientSha256 -ne $python.CipdClientSha256) {
    throw "The pinned CIPD client changed before it could be snapshotted."
  }
  $resolved = Invoke-DirectProcess -FilePath $snapshotCipdClient -Arguments @(
    "resolve",
    $python.CipdPackage,
    "-version", "version:$($python.CipdVersion)",
    "-application-default-credentials", "never",
    "-service-url", "https://chrome-infra-packages.appspot.com",
    "-log-level", "error"
  ) -WorkingDirectory $snapshotRoot -TimeoutSeconds 60 `
    -Description "authoritative Python CIPD version resolution" -SanitizeCipd
  $resolutionPattern = '(?m)^\s+' + [regex]::Escape($python.CipdPackage) + `
    ':([A-Za-z0-9_-]{40,64})\s*$'
  $resolutionMatch = [regex]::Match($resolved.StandardOutput, $resolutionPattern)
  if (-not $resolutionMatch.Success -or
      $resolutionMatch.Groups[1].Value -cne $python.CipdInstance) {
    throw "Installed Python metadata does not match the authoritative CIPD instance."
  }
  [IO.File]::WriteAllText(
    $pythonEnsureFile,
    "@Subdir python3`n$($python.CipdPackage) $($python.CipdInstance)`n",
    [Text.UTF8Encoding]::new($false)
  )
  [void](Invoke-DirectProcess -FilePath $snapshotCipdClient -Arguments @(
      "export",
      "-root", $pythonExportRoot,
      "-ensure-file", $pythonEnsureFile,
      "-application-default-credentials", "never",
      "-service-url", "https://chrome-infra-packages.appspot.com",
      "-log-level", "error"
    ) -WorkingDirectory $snapshotRoot -TimeoutSeconds $script:SevenZipTimeoutSeconds `
      -Description "authenticated Python CIPD export" -SanitizeCipd)
  $snapshotPythonRoot = Join-Path $pythonExportRoot "python3\bin"
  Assert-NoReparsePath -Path $snapshotPythonRoot -Recurse
  $pythonRuntimeTreeSha256 = Get-DirectoryTreeSha256 -Root $snapshotPythonRoot
  Assert-InstalledPythonMatchesAuthenticatedRuntime `
    -InstalledRoot $python.RuntimeRoot -AuthenticatedRoot $snapshotPythonRoot
  $snapshotPythonPath = Join-Path $snapshotPythonRoot "python3.exe"
  if ((Get-LowerSha256 -Path $snapshotPythonPath) -ne $python.Sha256) {
    throw "Installed python3.exe does not match its authenticated CIPD instance."
  }
  $runtimeArchiveToolSha256 = Copy-FileSnapshot -Source $runtimeArchiveTool `
    -Destination $snapshotRuntimeArchiveTool
  $dependencyStateToolSha256 = Copy-FileSnapshot -Source $dependencyStateTool `
    -Destination $snapshotDependencyStateTool
  if ($snapshotArgsSha256 -ne $gnArgsSha256) {
    throw "Snapshotted out\Kwiken\args.gn does not match the reviewed build configuration."
  }
  if ($snapshotSevenZipSha256 -ne $sevenZipSha256) {
    throw "Chromium's pinned 7za.exe changed before it could be snapshotted."
  }
  $pythonVersion = Get-PythonVersionText -PythonPath $snapshotPythonPath `
    -RuntimeRoot $snapshotPythonRoot -ExpectedExeSha256 $python.Sha256 `
    -ExpectedRuntimeTreeSha256 $pythonRuntimeTreeSha256
  $dependencyState = Invoke-DependencyStateCapture `
    -PythonPath $snapshotPythonPath -RuntimeRoot $snapshotPythonRoot `
    -ToolPath $snapshotDependencyStateTool -ExpectedExeSha256 $python.Sha256 `
    -ExpectedRuntimeTreeSha256 $pythonRuntimeTreeSha256 `
    -ExpectedToolSha256 $dependencyStateToolSha256 `
    -CheckoutRoot $ChromiumRoot -DepotToolsRoot $DepotToolsRoot `
    -DepotToolsRevision $script:DepotToolsRevision `
    -SourceDeltaSha256 $sourceDeltaSha256 `
    -OutputPath $snapshotDependencyStateManifest `
    -GclientJobs ([Math]::Min($Jobs, 32))

  $rawExtractRoot = Join-Path $stagingRoot "raw-extracted"
  Invoke-HardenedSevenZipExtraction -SevenZipPath $snapshotSevenZip `
    -ArchivePath $snapshotArchive -Destination $rawExtractRoot `
    -WorkingDirectory $snapshotRoot
  $topLevelEntries = @(Get-ChildItem -LiteralPath $rawExtractRoot -Force)
  if ($topLevelEntries.Count -ne 1 -or
      -not $topLevelEntries[0].PSIsContainer -or
      $topLevelEntries[0].Name -cne "Chrome-bin") {
    throw "Chromium's chrome.7z must contain exactly one Chrome-bin directory."
  }
  $runtimeSource = $topLevelEntries[0].FullName
  Assert-NoReparsePath -Path $runtimeSource -Recurse

  $criticalFiles = @(
    "chrome.exe",
    "chrome_proxy.exe",
    "$script:Version/chrome.dll",
    "$script:Version/resources.pak",
    "$script:Version/Locales/en-US.pak"
  )
  foreach ($relativePath in $criticalFiles) {
    $nativePath = Join-Path $runtimeSource $relativePath.Replace('/', '\')
    if (-not (Test-Path -LiteralPath $nativePath -PathType Leaf)) {
      throw "The native Chromium runtime is missing $relativePath."
    }
  }

  $nativeChromePath = Join-Path $runtimeSource "chrome.exe"
  $nativeProxyPath = Join-Path $runtimeSource "chrome_proxy.exe"
  $nativeDllPath = Join-Path $runtimeSource "$script:Version\chrome.dll"
  if ((Get-LowerSha256 -Path $nativeChromePath) -ne $chromeExeSha256) {
    throw "chrome.7z does not contain the chrome.exe produced by the incremental build."
  }
  Assert-Amd64Pe -Path $nativeChromePath -Description "Native chrome.exe"
  Assert-Amd64Pe -Path $nativeProxyPath -Description "Native chrome_proxy.exe"
  Assert-Amd64Pe -Path $nativeDllPath -Description "Native chrome.dll"
  Assert-Amd64Pe -Path $snapshotInstaller -Description "Native mini_installer.exe"
  Assert-Amd64Pe -Path $snapshotChrome -Description "Native output chrome.exe"
  Assert-KwikenPeIdentity -Path $nativeChromePath -Description "Native chrome.exe" `
    -ExpectedProductName "Kwiken" -RequireVersion
  Assert-KwikenPeIdentity -Path $nativeDllPath -Description "Native chrome.dll" `
    -ExpectedProductName "Kwiken" -RequireVersion
  Assert-KwikenPeIdentity -Path $snapshotInstaller `
    -Description "Native mini_installer.exe" `
    -ExpectedProductName "Kwiken Installer" -RequireVersion
  Invoke-RuntimeSmokeTest -RuntimeRoot $runtimeSource `
    -TemporaryRoot (Join-Path $stagingRoot "raw-smoke")

  $provenanceInputPaths = [Collections.Generic.List[string]]::new()
  foreach ($patch in $patchPaths) {
    $provenanceInputPaths.Add($patch.FullName)
  }
  foreach ($path in @(
      $repoArgsPath,
      (Join-Path $script:ForkRoot "VERSION"),
      (Join-Path $script:ForkRoot "PACKAGE_REVISION"),
      (Join-Path $script:ForkRoot "REVISION"),
      (Join-Path $script:ForkRoot "DEPOT_TOOLS_REVISION"),
      (Join-Path $script:ForkRoot "SOURCE_DELTA_SHA256"),
      (Join-Path $script:ForkRoot "scripts\apply-patches.ps1"),
      (Join-Path $script:ForkRoot "scripts\generate-brand-assets.ps1"),
      (Join-Path $script:ForkRoot "scripts\export-runtime.ps1"),
      $dependencyStateTool,
      $runtimeArchiveTool,
      (Join-Path $script:ForkRoot "assets\kwiken-icon.png"),
      (Join-Path $script:ForkRoot "assets\kwiken.ico")
    )) {
    $provenanceInputPaths.Add($path)
  }
  foreach ($asset in Get-ChildItem -LiteralPath (Join-Path $script:ForkRoot "assets\chromium") `
      -File -Recurse | Sort-Object FullName) {
    $provenanceInputPaths.Add($asset.FullName)
  }
  $sourceInputValues = [Collections.Generic.List[string]]::new()
  $sourceInputSnapshots = [Collections.Generic.List[object]]::new()
  foreach ($path in $provenanceInputPaths) {
    $relativePath = Get-RepositoryRelativePath -Path $path
    $inputSha256 = Get-LowerSha256 -Path $path
    if ($path -eq $runtimeArchiveTool -and
        $inputSha256 -ne $runtimeArchiveToolSha256) {
      throw "runtime_archive.py changed after its private snapshot was created."
    }
    if ($path -eq $dependencyStateTool -and
        $inputSha256 -ne $dependencyStateToolSha256) {
      throw "dependency_state.py changed after its private snapshot was created."
    }
    $sourceInputValues.Add("$relativePath=$inputSha256")
    $sourceInputSnapshots.Add([pscustomobject]@{
      Path = $path
      Sha256 = $inputSha256
    })
  }

  $archiveFileName = "$publicationName.zip"
  $manifestFileName = "$publicationName.provenance.json"
  $stagedArchive = Join-Path $publicationRoot $archiveFileName
  $stagedManifest = Join-Path $publicationRoot $manifestFileName
  $packArguments = [Collections.Generic.List[string]]::new()
  foreach ($argument in @(
      "pack",
      "--source", $runtimeSource,
      "--archive", $stagedArchive,
      "--manifest", $stagedManifest,
      "--archive-root", $archiveRootName,
      "--version", $script:Version,
      "--package-revision", $script:PackageRevision,
      "--release-version", $script:ReleaseVersion,
      "--kwiken-revision", $repositoryRevision,
      "--chromium-revision", $script:Revision,
      "--depot-tools-revision", $script:DepotToolsRevision,
      "--source-delta-sha256", $sourceDeltaSha256,
      "--dependency-state-manifest", $snapshotDependencyStateManifest,
      "--gn-args-sha256", $gnArgsSha256,
      "--chrome-7z-sha256", $chrome7zSha256,
      "--chrome-exe-sha256", $chromeExeSha256,
      "--mini-installer-sha256", $miniInstallerSha256,
      "--build-command-line", $buildCommandLine,
      "--build-jobs", [string]$Jobs,
      "--visual-studio-version", $visualStudioVersion,
      "--windows-sdk-version", $sdkVersion.ToString(),
      "--windows-debugger-version", $debuggerVersion.ToString(),
      "--python-version", $pythonVersion,
      "--python-cipd-package", $python.CipdPackage,
      "--python-cipd-version", $python.CipdVersion,
      "--python-cipd-instance", $python.CipdInstance,
      "--cipd-client-version", $python.CipdClientVersion,
      "--cipd-client-sha256", $python.CipdClientSha256,
      "--python-path", $python.RelativePath,
      "--python-runtime-tree-sha256", $pythonRuntimeTreeSha256,
      "--python-sha256", $python.Sha256,
      "--seven-zip-path", $script:PinnedSevenZipRelativePath,
      "--seven-zip-sha256", $sevenZipSha256,
      "--output-directory", "out/Kwiken"
    )) {
    $packArguments.Add([string]$argument)
  }
  foreach ($value in $sourceInputValues) {
    $packArguments.Add("--source-input")
    $packArguments.Add($value)
  }
  foreach ($relativePath in $criticalFiles) {
    $packArguments.Add("--require")
    $packArguments.Add($relativePath)
  }
  Invoke-PythonRuntimeArchive -PythonPath $snapshotPythonPath `
    -ToolPath $snapshotRuntimeArchiveTool -Arguments $packArguments.ToArray() `
    -RuntimeRoot $snapshotPythonRoot -ExpectedExeSha256 $python.Sha256 `
    -ExpectedRuntimeTreeSha256 $pythonRuntimeTreeSha256 `
    -ExpectedToolSha256 $runtimeArchiveToolSha256

  $expectedArtifactSha256 = Get-LowerSha256 -Path $stagedArchive
  $expectedArtifactSize = (Get-Item -LiteralPath $stagedArchive).Length
  $verifiedExtractRoot = Join-Path $stagingRoot "verified-extracted"
  $verifyArguments = [Collections.Generic.List[string]]::new()
  foreach ($argument in @(
      "verify",
      "--archive", $stagedArchive,
      "--manifest", $stagedManifest,
      "--extract-to", $verifiedExtractRoot,
      "--expect-version", $script:Version,
      "--expect-package-revision", $script:PackageRevision,
      "--expect-release-version", $script:ReleaseVersion,
      "--expect-kwiken-revision", $repositoryRevision,
      "--expect-chromium-revision", $script:Revision,
      "--expect-depot-tools-revision", $script:DepotToolsRevision,
      "--expect-source-delta-sha256", $sourceDeltaSha256,
      "--expect-dependency-state-tree-sha256", $dependencyState.TreeSha256,
      "--expect-gn-args-sha256", $gnArgsSha256,
      "--expect-artifact-sha256", $expectedArtifactSha256,
      "--expect-artifact-size", [string]$expectedArtifactSize,
      "--expect-chrome-7z-sha256", $chrome7zSha256,
      "--expect-chrome-exe-sha256", $chromeExeSha256,
      "--expect-mini-installer-sha256", $miniInstallerSha256,
      "--expect-build-command-line", $buildCommandLine,
      "--expect-build-jobs", [string]$Jobs,
      "--expect-output-directory", "out/Kwiken",
      "--expect-visual-studio-version", $visualStudioVersion,
      "--expect-windows-sdk-version", $sdkVersion.ToString(),
      "--expect-windows-debugger-version", $debuggerVersion.ToString(),
      "--expect-python-version", $pythonVersion,
      "--expect-python-cipd-package", $python.CipdPackage,
      "--expect-python-cipd-version", $python.CipdVersion,
      "--expect-python-cipd-instance", $python.CipdInstance,
      "--expect-cipd-client-version", $python.CipdClientVersion,
      "--expect-cipd-client-sha256", $python.CipdClientSha256,
      "--expect-python-path", $python.RelativePath,
      "--expect-python-runtime-tree-sha256", $pythonRuntimeTreeSha256,
      "--expect-python-sha256", $python.Sha256,
      "--expect-seven-zip-path", $script:PinnedSevenZipRelativePath,
      "--expect-seven-zip-sha256", $sevenZipSha256,
      "--max-files", [string]$script:MaximumRuntimeFiles,
      "--max-uncompressed-bytes", [string]$script:MaximumRuntimeBytes,
      "--max-archive-bytes", [string]$script:MaximumRuntimeArchiveBytes,
      "--require-clean-source"
    )) {
    $verifyArguments.Add([string]$argument)
  }
  foreach ($value in $sourceInputValues) {
    $verifyArguments.Add("--expect-source-input")
    $verifyArguments.Add($value)
  }
  Invoke-PythonRuntimeArchive -PythonPath $snapshotPythonPath `
    -ToolPath $snapshotRuntimeArchiveTool -Arguments $verifyArguments.ToArray() `
    -RuntimeRoot $snapshotPythonRoot -ExpectedExeSha256 $python.Sha256 `
    -ExpectedRuntimeTreeSha256 $pythonRuntimeTreeSha256 `
    -ExpectedToolSha256 $runtimeArchiveToolSha256

  $verifiedRuntimeRoot = Join-Path $verifiedExtractRoot $archiveRootName
  Assert-NoReparsePath -Path $verifiedRuntimeRoot -Recurse
  Assert-Amd64Pe -Path (Join-Path $verifiedRuntimeRoot "chrome.exe") `
    -Description "Verified normalized chrome.exe"
  Assert-Amd64Pe -Path (Join-Path $verifiedRuntimeRoot "chrome_proxy.exe") `
    -Description "Verified normalized chrome_proxy.exe"
  Assert-Amd64Pe -Path (Join-Path $verifiedRuntimeRoot "$script:Version\chrome.dll") `
    -Description "Verified normalized chrome.dll"
  Assert-KwikenPeIdentity -Path (Join-Path $verifiedRuntimeRoot "chrome.exe") `
    -Description "Verified normalized chrome.exe" `
    -ExpectedProductName "Kwiken" -RequireVersion
  Invoke-RuntimeSmokeTest -RuntimeRoot $verifiedRuntimeRoot `
    -TemporaryRoot (Join-Path $stagingRoot "verified-smoke")

  $readyPath = Join-Path $publicationRoot "RELEASE.READY.json"
  $ready = [ordered]@{
    schemaVersion = 1
    releaseVersion = $script:ReleaseVersion
    archive = [ordered]@{
      fileName = $archiveFileName
      sha256 = Get-LowerSha256 -Path $stagedArchive
    }
    manifest = [ordered]@{
      fileName = $manifestFileName
      sha256 = Get-LowerSha256 -Path $stagedManifest
    }
  }
  [IO.File]::WriteAllText(
    $readyPath,
    (($ready | ConvertTo-Json -Depth 5) + "`n"),
    [Text.UTF8Encoding]::new($false)
  )

  Assert-CleanKwikenRepository
  $finalRepositoryRevision = (& git -C $script:RepoRoot rev-parse HEAD).Trim()
  if ($LASTEXITCODE -ne 0 -or $finalRepositoryRevision -cne $repositoryRevision) {
    throw "The Kwiken repository revision changed during release staging."
  }
  if ((Assert-KwikenSourceDelta -SourceRoot $sourceRoot) -ne $sourceDeltaSha256) {
    throw "The Chromium source delta changed during release staging."
  }
  foreach ($sourceInput in $sourceInputSnapshots) {
    if ((Get-LowerSha256 -Path $sourceInput.Path) -ne $sourceInput.Sha256) {
      throw "A release provenance input changed during staging: $($sourceInput.Path)"
    }
  }
  Assert-DepotToolsCheckout -DepotToolsRoot $DepotToolsRoot
  $finalDependencyStateManifest = Join-Path $snapshotRoot "dependency-state-final.json"
  $finalDependencyState = Invoke-DependencyStateCapture `
    -PythonPath $snapshotPythonPath -RuntimeRoot $snapshotPythonRoot `
    -ToolPath $snapshotDependencyStateTool -ExpectedExeSha256 $python.Sha256 `
    -ExpectedRuntimeTreeSha256 $pythonRuntimeTreeSha256 `
    -ExpectedToolSha256 $dependencyStateToolSha256 `
    -CheckoutRoot $ChromiumRoot -DepotToolsRoot $DepotToolsRoot `
    -DepotToolsRevision $script:DepotToolsRevision `
    -SourceDeltaSha256 $sourceDeltaSha256 `
    -OutputPath $finalDependencyStateManifest `
    -GclientJobs ([Math]::Min($Jobs, 32))
  if ($finalDependencyState.ManifestSha256 -cne $dependencyState.ManifestSha256 -or
      $finalDependencyState.TreeSha256 -cne $dependencyState.TreeSha256) {
    throw "The Chromium dependency state changed during release staging."
  }
  if (Get-Item -LiteralPath $finalDirectory -Force -ErrorAction SilentlyContinue) {
    throw "Runtime release appeared while staging; refusing overwrite: $finalDirectory"
  }
  [void](Set-PublicationAclForAtomicMove -PublicationRoot $publicationRoot `
      -DestinationParent $OutputDirectory)
  # The protected destination-equivalent ACL was verified above. Directory.Move
  # is the publication commit and intentionally remains the last operation that
  # can fail before the success result is assembled.
  [IO.Directory]::Move($publicationRoot, $finalDirectory)
  $published = $true

  $releaseResult = [pscustomobject]@{
    ReleaseDirectory = $finalDirectory
    ReadyPath = Join-Path $finalDirectory "RELEASE.READY.json"
    ArchivePath = Join-Path $finalDirectory $archiveFileName
    ArchiveSha256 = $ready.archive.sha256
    ManifestPath = Join-Path $finalDirectory $manifestFileName
    ManifestSha256 = $ready.manifest.sha256
    ReleaseVersion = $script:ReleaseVersion
    SourceRevision = $repositoryRevision
    SourceDirty = $false
  }
} catch {
  $exportFailure = $_
} finally {
  try {
    Remove-ExportStagingDirectory -Path $stagingRoot -Parent $OutputDirectory
  } catch {
    if ($published -or $null -ne $exportFailure) {
      Write-Warning -Message `
        "Private staging cleanup failed: $($_.Exception.Message)" `
        -WarningAction Continue
    } else {
      throw
    }
  }
}
if ($null -ne $exportFailure) {
  throw $exportFailure
}
$releaseResult
