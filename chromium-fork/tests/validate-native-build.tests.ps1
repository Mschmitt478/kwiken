param(
  [switch]$SkipNativeFixtures
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path (Split-Path -Parent $PSScriptRoot) "scripts\validate-native-build.ps1")

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

function Assert-Throws {
  param(
    [Parameter(Mandatory = $true)]
    [scriptblock]$Body,
    [Parameter(Mandatory = $true)]
    [string]$Pattern
  )
  try {
    $null = & $Body
  } catch {
    if ($_.Exception.Message -notmatch $Pattern) {
      throw "Expected error matching '$Pattern', got '$($_.Exception.Message)'."
    }
    return
  }
  throw "Expected an error matching '$Pattern'."
}

function New-TestArchiveEntry {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Path,
    [AllowNull()]
    [Nullable[long]]$Size = 10,
    [string]$Encrypted = "-",
    [bool]$IsFolder = $false,
    [string]$Attributes,
    [object[]]$LinkOrReparseFields = @(),
    [bool]$HasLinkOrReparseMetadata = $false
  )

  if ([string]::IsNullOrEmpty($Attributes)) {
    $Attributes = $(if ($IsFolder) { "D" } else { "A" })
  }
  return [pscustomobject]@{
    Path = $Path
    Size = $Size
    Attributes = $Attributes
    Encrypted = $Encrypted
    IsFolder = $IsFolder
    LinkOrReparseFields = $LinkOrReparseFields
    HasLinkOrReparseMetadata = $HasLinkOrReparseMetadata
  }
}

function New-ValidArchiveEntries {
  $version = "150.0.7871.186"
  return @(
    (New-TestArchiveEntry -Path "Chrome-bin" -Size 0 -IsFolder $true),
    (New-TestArchiveEntry -Path "Chrome-bin\chrome.exe"),
    (New-TestArchiveEntry -Path "Chrome-bin\chrome_proxy.exe"),
    (New-TestArchiveEntry -Path "Chrome-bin\$version\chrome.dll"),
    (New-TestArchiveEntry -Path "Chrome-bin\$version\resources.pak"),
    (New-TestArchiveEntry -Path "Chrome-bin\$version\Locales\en-US.pak")
  )
}

Invoke-Test "7za technical listing parser returns structured entries" {
  $listing = @'
Listing archive: C:\build\chrome.7z

--
Path = C:\build\chrome.7z
Type = 7z

----------
Path = Chrome-bin\chrome.exe
Size = 10
Attributes = A
Encrypted = -

Path = Chrome-bin\150.0.7871.186\chrome.dll
Size = 20
Folder = -
Encrypted = -
'@
  $entries = @(ConvertFrom-KwikenSevenZipTechnicalListing -Lines @(
      $listing -split "`r?`n"
    ))
  Assert-True -Condition ($entries.Count -eq 2) `
    -Message "The parser returned archive metadata or lost an entry."
  Assert-True -Condition ($entries[0].Path -eq "Chrome-bin\chrome.exe") `
    -Message "The first archive path was parsed incorrectly."
  Assert-True -Condition ($entries[0].Size -eq 10 -and -not $entries[0].IsFolder) `
    -Message "The parser did not preserve regular-file metadata."
  Assert-True -Condition ($entries[1].Encrypted -eq "-") `
    -Message "The parser did not preserve encryption metadata."
}

Invoke-Test "7za parser preserves link and reparse metadata" {
  $listing = @'
----------
Path = Chrome-bin\linked.dll
Size = 4
Encrypted = -
Symbolic Link = ..\target.dll

Path = Chrome-bin\hard-linked.dll
Size = 4
Encrypted = -
HardLink = Chrome-bin\target.dll

Path = Chrome-bin\junction
Size = 0
Encrypted = -
Reparse Point = junction-data
'@
  $entries = @(ConvertFrom-KwikenSevenZipTechnicalListing -Lines @(
      $listing -split "`r?`n"
    ))
  Assert-True -Condition ($entries.Count -eq 3) `
    -Message "The parser lost a link/reparse entry."
  foreach ($entry in $entries) {
    Assert-True -Condition $entry.HasLinkOrReparseMetadata `
      -Message "Link/reparse metadata was not marked active for $($entry.Path)."
    Assert-True -Condition ($entry.LinkOrReparseFields.Count -eq 1) `
      -Message "Link/reparse fields were not preserved for $($entry.Path)."
  }
}

Invoke-Test "Chrome-bin layout accepts the pinned version" {
  $layout = Assert-KwikenChromeArchiveLayout -ExpectedVersion "150.0.7871.186" `
    -Entries (New-ValidArchiveEntries)
  Assert-True -Condition ($layout.EntryCount -eq 6) `
    -Message "The valid archive layout returned the wrong entry count."
}

Invoke-Test "native and archived chrome.dll paths preserve their distinct layouts" {
  $validatorPath = Join-Path (Split-Path -Parent $PSScriptRoot) `
    "scripts\validate-native-build.ps1"
  $validatorText = [IO.File]::ReadAllText($validatorPath)
  Assert-True `
    -Condition $validatorText.Contains('-Source (Join-Path $outputRoot "chrome.dll")') `
    -Message "Native validation no longer snapshots out\Kwiken\chrome.dll."
  Assert-True `
    -Condition $validatorText.Contains('"Chrome-bin\$ExpectedVersion\chrome.dll"') `
    -Message "Archive validation no longer uses Chrome-bin\<version>\chrome.dll."
  Assert-True -Condition ($script:KwikenInstallerStubMachine -eq [UInt16]0x8664) `
    -Message "The Chromium x64 mini-installer stub machine is not explicitly AMD64."
}

Invoke-Test "Chrome-bin layout requires chrome_proxy and critical file metadata" {
  $withoutProxy = @(New-ValidArchiveEntries | Where-Object {
    $_.Path -ne "Chrome-bin\chrome_proxy.exe"
  })
  Assert-Throws -Pattern "chrome_proxy.exe" -Body {
    Assert-KwikenChromeArchiveLayout -ExpectedVersion "150.0.7871.186" `
      -Entries $withoutProxy
  }

  $emptyChrome = @(New-ValidArchiveEntries | ForEach-Object {
    if ($_.Path -eq "Chrome-bin\chrome.exe") {
      New-TestArchiveEntry -Path $_.Path -Size 0
    } else {
      $_
    }
  })
  Assert-Throws -Pattern "empty or has no valid size" -Body {
    Assert-KwikenChromeArchiveLayout -ExpectedVersion "150.0.7871.186" `
      -Entries $emptyChrome
  }

  $directoryChrome = @(New-ValidArchiveEntries | ForEach-Object {
    if ($_.Path -eq "Chrome-bin\chrome.exe") {
      New-TestArchiveEntry -Path $_.Path -IsFolder $true
    } else {
      $_
    }
  })
  Assert-Throws -Pattern "directory, not a regular file" -Body {
    Assert-KwikenChromeArchiveLayout -ExpectedVersion "150.0.7871.186" `
      -Entries $directoryChrome
  }

  $encryptedChrome = @(New-ValidArchiveEntries | ForEach-Object {
    if ($_.Path -eq "Chrome-bin\chrome.exe") {
      New-TestArchiveEntry -Path $_.Path -Encrypted "+"
    } else {
      $_
    }
  })
  Assert-Throws -Pattern "encrypted" -Body {
    Assert-KwikenChromeArchiveLayout -ExpectedVersion "150.0.7871.186" `
      -Entries $encryptedChrome
  }
}

Invoke-Test "critical extraction rejects substituted sizes before launching 7za" {
  Assert-Throws -Pattern "corresponding native output" -Body {
    Expand-KwikenValidatedCriticalArchiveFiles `
      -SevenZipPath "unused-7za.exe" -ArchivePath "unused-chrome.7z" `
      -Entries (New-ValidArchiveEntries) `
      -ExpectedVersion "150.0.7871.186" `
      -Destination (Join-Path ([IO.Path]::GetTempPath()) "unused-extraction") `
      -ExpectedSizes @{
        "Chrome-bin\chrome.exe" = 11
        "Chrome-bin\chrome_proxy.exe" = 10
        "Chrome-bin\150.0.7871.186\chrome.dll" = 10
      } -TimeoutSeconds 1
  }
}

Invoke-Test "archive paths reject unsafe Windows names" {
  $unsafeCases = @(
    @("..\payload.dll", "traversal"),
    @("Chrome-bin\.\payload.dll", "traversal"),
    @("\rooted\payload.dll", "rooted"),
    @("/rooted/payload.dll", "rooted"),
    @("C:\payload.dll", "colon"),
    @("Chrome-bin\payload.dll:stream", "colon"),
    @("Chrome-bin\\payload.dll", "empty segment"),
    @("Chrome-bin\payload.dll\", "empty segment")
  )
  foreach ($case in $unsafeCases) {
    Assert-Throws -Pattern $case[1] -Body {
      Assert-KwikenSafeArchiveEntries -Entries @(
        (New-TestArchiveEntry -Path $case[0])
      )
    }
  }

  Assert-Throws -Pattern "case-insensitive duplicate" -Body {
    Assert-KwikenSafeArchiveEntries -Entries @(
      (New-TestArchiveEntry -Path "Chrome-bin\chrome.exe"),
      (New-TestArchiveEntry -Path "chrome-BIN/chrome.EXE")
    )
  }
}

Invoke-Test "archive paths reject forbidden characters and device names" {
  $forbiddenPaths = @(
    "Chrome-bin\less<than.dll",
    "Chrome-bin\greater>than.dll",
    'Chrome-bin\double"quote.dll',
    "Chrome-bin\pipe|name.dll",
    "Chrome-bin\question?.dll",
    "Chrome-bin\star*.dll",
    "Chrome-bin\control$([char]1).dll",
    "Chrome-bin\trailing-dot.",
    "Chrome-bin\trailing-space "
  )
  foreach ($path in $forbiddenPaths) {
    Assert-Throws -Pattern "forbidden|control character|ending in a dot or space" -Body {
      Assert-KwikenSafeArchiveEntries -Entries @(
        (New-TestArchiveEntry -Path $path)
      )
    }
  }

  $superscriptOne = [char]0x00B9
  $superscriptTwo = [char]0x00B2
  $superscriptThree = [char]0x00B3
  $reservedSegments = @(
    "CON", "prn.txt", "AUX", "nul.dat",
    "COM1", "com9.log", "LPT1", "lpt9.log",
    "COM$superscriptOne", "LPT$superscriptOne.txt",
    "COM$superscriptTwo", "LPT$superscriptTwo.txt",
    "COM$superscriptThree", "LPT$superscriptThree.txt",
    'CONIN$', 'conout$.txt', "CON .txt"
  )
  foreach ($segment in $reservedSegments) {
    Assert-Throws -Pattern "reserved Windows device name" -Body {
      Assert-KwikenSafeArchiveEntries -Entries @(
        (New-TestArchiveEntry -Path "Chrome-bin\$segment")
      )
    }
  }

  $safeDeviceLikeEntries = @(Assert-KwikenSafeArchiveEntries -Entries @(
    (New-TestArchiveEntry -Path "Chrome-bin\COM0.dll"),
    (New-TestArchiveEntry -Path "Chrome-bin\LPT10.dll")
  ))
  Assert-True -Condition ($safeDeviceLikeEntries.Count -eq 2) `
    -Message "Non-reserved device-like names were rejected."
}

Invoke-Test "all regular entries require size and no encryption" {
  Assert-Throws -Pattern "nonnegative size" -Body {
    Assert-KwikenSafeArchiveEntries -Entries @(
      (New-TestArchiveEntry -Path "Chrome-bin\optional.dll" -Size $null)
    )
  }
  Assert-Throws -Pattern "nonnegative size" -Body {
    Assert-KwikenSafeArchiveEntries -Entries @(
      (New-TestArchiveEntry -Path "Chrome-bin\optional.dll" -Size -1)
    )
  }
  Assert-Throws -Pattern "encrypted" -Body {
    Assert-KwikenSafeArchiveEntries -Entries @(
      (New-TestArchiveEntry -Path "Chrome-bin\optional.dll" -Encrypted "+")
    )
  }
  $emptyRegularEntry = @(Assert-KwikenSafeArchiveEntries -Entries @(
    (New-TestArchiveEntry -Path "Chrome-bin\optional.empty" -Size 0)
  ))
  Assert-True -Condition ($emptyRegularEntry.Count -eq 1) `
    -Message "A nonnegative zero-sized noncritical file was rejected."
}

Invoke-Test "archive entries reject links and reparse-like metadata" {
  foreach ($fieldName in @("Symbolic Link", "Hard Link", "Reparse Point")) {
    $linkField = [pscustomobject]@{ Name = $fieldName; Value = "target" }
    Assert-Throws -Pattern "symbolic link, hard link, or reparse-like" -Body {
      Assert-KwikenSafeArchiveEntries -Entries @(
        (New-TestArchiveEntry -Path "Chrome-bin\linked.dll" `
          -LinkOrReparseFields @($linkField) -HasLinkOrReparseMetadata $true)
      )
    }
  }
  Assert-Throws -Pattern "symbolic link, hard link, or reparse-like" -Body {
    Assert-KwikenSafeArchiveEntries -Entries @(
      (New-TestArchiveEntry -Path "Chrome-bin\unix-link" `
        -Attributes "A_ lrwxrwxrwx" -HasLinkOrReparseMetadata $true)
    )
  }
}

Invoke-Test "Chrome-bin layout rejects foreign entries" {
  $withForeignEntry = @(New-ValidArchiveEntries)
  $withForeignEntry += New-TestArchiveEntry -Path "Other-root\payload.dll"
  Assert-Throws -Pattern "outside Chrome-bin" -Body {
    Assert-KwikenChromeArchiveLayout -ExpectedVersion "150.0.7871.186" `
      -Entries $withForeignEntry
  }
}

Invoke-Test "bounded process terminates its exact child" {
  $pingPath = Join-Path $env:SystemRoot "System32\ping.exe"
  Assert-Throws -Pattern "timed out after 1 seconds and was terminated" -Body {
    Invoke-KwikenBoundedProcess -FilePath $pingPath `
      -Arguments "-n 20 127.0.0.1" -WorkingDirectory $env:TEMP `
      -TimeoutSeconds 1
  }
}

Invoke-Test "bounded process rejects oversized standard output" {
  $shellPath = (Get-Process -Id $PID).Path
  $arguments = Join-KwikenWindowsCommandLineArguments -Arguments @(
    "-NoLogo",
    "-NoProfile",
    "-NonInteractive",
    "-Command",
    "[Console]::Out.Write(('x' * 4096)); Start-Sleep -Seconds 2"
  )
  Assert-Throws -Pattern "standard output capture limit" -Body {
    Invoke-KwikenBoundedProcess -FilePath $shellPath -Arguments $arguments `
      -WorkingDirectory ([IO.Path]::GetTempPath()) -TimeoutSeconds 10 `
      -MaximumStandardOutputBytes 128 | Out-Null
  }
}

Invoke-Test "private validation directory is protected and exactly cleaned" {
  $temporaryParent = [IO.Path]::GetTempPath()
  $privatePath = New-KwikenPrivateValidationDirectory -Parent $temporaryParent
  try {
    $acl = Get-Acl -LiteralPath $privatePath
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier])
    $expectedOwner = [Security.Principal.WindowsIdentity]::GetCurrent().User
    Assert-True -Condition ($owner -eq $expectedOwner) `
      -Message "The validation directory has the wrong owner."
    Assert-True -Condition $acl.AreAccessRulesProtected `
      -Message "The validation directory ACL is not protected."
  } finally {
    Remove-KwikenPrivateValidationDirectory -Path $privatePath `
      -Parent $temporaryParent
  }
  Assert-True -Condition (-not (Test-Path -LiteralPath $privatePath)) `
    -Message "The private validation directory was not removed."
}

if ($SkipNativeFixtures) {
  Write-Output "SKIP pinned 7za integrity test rejects bad CRC data (-SkipNativeFixtures)"
} else {
  Invoke-Test "pinned 7za integrity test rejects bad CRC data" {
    $sourceRoot = Join-Path (Get-DefaultChromiumRoot) "src"
    $sevenZipPath = Join-Path $sourceRoot `
      "third_party\lzma_sdk\bin\host_platform\7za.exe"
    $badCrcArchive = Join-Path $sourceRoot `
      "third_party\lzma_sdk\google\test_data\bad_crc.7z"
    Assert-True -Condition (Test-Path -LiteralPath $badCrcArchive -PathType Leaf) `
      -Message "Chromium's pinned bad_crc.7z fixture is missing."
    Assert-Throws -Pattern "integrity test" -Body {
      Test-KwikenSevenZipArchive -SevenZipPath $sevenZipPath `
        -ArchivePath $badCrcArchive -TimeoutSeconds 30
    }
  }
}

Invoke-Test "PE metadata validator compares fixed version fields" {
  $enginePath = (Get-Process -Id $PID).Path
  $engine = Get-Item -LiteralPath $enginePath
  $versionInfo = $engine.VersionInfo
  $expectedVersion = "{0}.{1}.{2}.{3}" -f @(
    $versionInfo.FileMajorPart,
    $versionInfo.FileMinorPart,
    $versionInfo.FileBuildPart,
    $versionInfo.FilePrivatePart
  )
  $expectedMachine = Get-KwikenPeMachine -Path $enginePath -Name "test engine"
  $artifact = Get-KwikenPeArtifact -Path $enginePath -Name "test engine" `
    -ExpectedProductName $versionInfo.ProductName -ExpectedVersion $expectedVersion `
    -ExpectedMachine $expectedMachine -ExpectedMachineName "test engine machine"
  Assert-True -Condition ($artifact.FileVersion -eq $expectedVersion) `
    -Message "The PE numeric file version was not preserved."
  Assert-True -Condition ($artifact.Machine -eq $expectedMachine) `
    -Message "The PE machine was not preserved."
  Assert-Throws -Pattern "ProductName" -Body {
    Get-KwikenPeArtifact -Path $enginePath -Name "test engine" `
      -ExpectedProductName "Definitely not this product" `
      -ExpectedVersion $expectedVersion -ExpectedMachine $expectedMachine `
      -ExpectedMachineName "test engine machine"
  }
}

Invoke-Test "PE validation rejects corrupt and non-AMD64 payloads" {
  $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("Kwiken-Native-PE-Test-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $temporaryRoot -ErrorAction Stop | Out-Null
  try {
    $corruptPath = Join-Path $temporaryRoot "corrupt.exe"
    [IO.File]::WriteAllBytes($corruptPath, [byte[]]::new(128))
    Assert-Throws -Pattern "not a valid PE image" -Body {
      Get-KwikenPeMachine -Path $corruptPath -Name "corrupt.exe"
    }

    $enginePath = (Get-Process -Id $PID).Path
    $engine = Get-Item -LiteralPath $enginePath
    $versionInfo = $engine.VersionInfo
    $expectedVersion = "{0}.{1}.{2}.{3}" -f @(
      $versionInfo.FileMajorPart,
      $versionInfo.FileMinorPart,
      $versionInfo.FileBuildPart,
      $versionInfo.FilePrivatePart
    )
    $nonAmd64Path = Join-Path $temporaryRoot "non-amd64.exe"
    $bytes = [IO.File]::ReadAllBytes($enginePath)
    $headerOffset = [BitConverter]::ToUInt32($bytes, 0x3c)
    [BitConverter]::GetBytes([UInt16]0x014c).CopyTo(
      $bytes,
      [int]$headerOffset + 4
    )
    [IO.File]::WriteAllBytes($nonAmd64Path, $bytes)
    Assert-Throws -Pattern "expected AMD64 \(0x8664\)" -Body {
      Get-KwikenPeArtifact -Path $nonAmd64Path -Name "non-amd64.exe" `
        -ExpectedProductName $versionInfo.ProductName `
        -ExpectedVersion $expectedVersion `
        -ExpectedMachine ([UInt16]0x8664) -ExpectedMachineName "AMD64"
    }
  } finally {
    $leaf = Split-Path -Leaf $temporaryRoot
    if ($leaf -notmatch '^Kwiken-Native-PE-Test-[0-9a-f]{32}$') {
      throw "Refusing to remove unexpected PE test directory: $temporaryRoot"
    }
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction Stop
  }
}

Invoke-Test "critical payload hash comparison rejects substitution" {
  $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("Kwiken-Native-Hash-Test-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $temporaryRoot -ErrorAction Stop | Out-Null
  try {
    $nativePath = Join-Path $temporaryRoot "native.bin"
    $matchingPath = Join-Path $temporaryRoot "matching.bin"
    $substitutedPath = Join-Path $temporaryRoot "substituted.bin"
    [IO.File]::WriteAllBytes($nativePath, [Text.Encoding]::UTF8.GetBytes("native"))
    [void](Copy-KwikenValidationSnapshot -Source $nativePath `
        -Destination $matchingPath -Name "native.bin")
    [IO.File]::WriteAllBytes(
      $substitutedPath,
      [Text.Encoding]::UTF8.GetBytes("substituted")
    )
    $matchingHash = Assert-KwikenMatchingFileHash -ExpectedPath $nativePath `
      -ActualPath $matchingPath -Name "chrome.exe"
    Assert-True -Condition ($matchingHash.Length -eq 64) `
      -Message "Matching critical payload did not return its SHA-256."
    Assert-Throws -Pattern "does not match the corresponding native output" -Body {
      Assert-KwikenMatchingFileHash -ExpectedPath $nativePath `
        -ActualPath $substitutedPath -Name "chrome.exe"
    }
  } finally {
    $leaf = Split-Path -Leaf $temporaryRoot
    if ($leaf -notmatch '^Kwiken-Native-Hash-Test-[0-9a-f]{32}$') {
      throw "Refusing to remove unexpected hash test directory: $temporaryRoot"
    }
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction Stop
  }
}

if ($failures.Count -gt 0) {
  throw "Native-build validation tests failed:`n$($failures -join [Environment]::NewLine)"
}
Write-Output "All native-build validation tests passed."
