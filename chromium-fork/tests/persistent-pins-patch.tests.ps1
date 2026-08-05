$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$patchPath = Join-Path (Split-Path -Parent $PSScriptRoot) `
  "patches\0003-kwiken-persistent-pins.patch"

if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
  throw "Persistent-pins patch is missing: $patchPath"
}

$patch = [IO.File]::ReadAllText($patchPath)
$failures = [Collections.Generic.List[string]]::new()

function Assert-PatchMatch {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [string]$Pattern
  )

  if ($patch -notmatch $Pattern) {
    $script:failures.Add("$Name (missing pattern: $Pattern)")
  }
}

function Assert-PatchDoesNotMatch {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [string]$Pattern
  )

  if ($patch -match $Pattern) {
    $script:failures.Add("$Name (forbidden pattern: $Pattern)")
  }
}

$expectedFiles = @(
  "chrome/browser/ui/browser_live_tab_context.cc",
  "chrome/browser/ui/browser_tabrestore.cc",
  "chrome/browser/ui/browser_tabrestore_browsertest.cc",
  "chrome/browser/ui/tabs/pinned_tab_codec.cc",
  "chrome/browser/ui/tabs/pinned_tab_codec.h",
  "chrome/browser/ui/tabs/pinned_tab_codec_browsertest.cc",
  "chrome/browser/ui/tabs/pinned_tab_service.cc",
  "chrome/browser/ui/tabs/pinned_tab_service.h",
  "chrome/browser/ui/tabs/pinned_tab_service_browsertest.cc",
  "chrome/browser/ui/tabs/pinned_tab_service_factory.cc"
)
$actualFiles = @(
  [regex]::Matches($patch, '(?m)^diff --git a/(.+?) b/') |
    ForEach-Object { $_.Groups[1].Value }
)
$unexpectedFiles = @($actualFiles | Where-Object { $_ -notin $expectedFiles })
$missingFiles = @($expectedFiles | Where-Object { $_ -notin $actualFiles })
if ($unexpectedFiles.Count -gt 0) {
  $failures.Add("Patch touches unexpected files: $($unexpectedFiles -join ', ')")
}
if ($missingFiles.Count -gt 0) {
  $failures.Add("Patch omits expected files: $($missingFiles -join ', ')")
}

Assert-PatchMatch "versioned v1 records" `
  'kCurrentRecordVersion = 1[\s\S]+record_version[\s\S]+kId[\s\S]+kURL[\s\S]+kTitle'
Assert-PatchMatch "canonical UUID validation" `
  'base::Uuid::ParseCaseInsensitive'
Assert-PatchMatch "new UUID generation" `
  'base::Uuid::GenerateRandomV4\(\)\.AsLowercaseString\(\)'
Assert-PatchMatch "duplicate URL identity coverage" `
  'VersionedRecordsPreserveDuplicateUrlIdentityAndOrder'
Assert-PatchMatch "corrupt duplicate UUID repair" `
  'duplicated session extra-data UUID is corrupt[\s\S]+GenerateUniqueId\(\)'
Assert-PatchMatch "legacy record migration" `
  'legacy format[\s\S]+needs_migration'
Assert-PatchMatch "future schema preservation" `
  'IsUnknownFutureRecord[\s\S]+old_value\.Clone\(\)'
Assert-PatchMatch "favicon continuity derives from profile cache" `
  'profile-scoped history/favicon cache'
Assert-PatchMatch "favicons are not serialized" `
  'Find\("favicon"\)'

Assert-PatchMatch "stable session identity key" `
  'kwiken_pinned_tab_id'
Assert-PatchMatch "BrowserLiveTabContext emits identity" `
  'BrowserLiveTabContext::GetExtraDataForTab[\s\S]+PopulateExtraDataForTab'
Assert-PatchMatch "ongoing SessionService command" `
  'SessionServiceFactory::GetForProfile[\s\S]+AddTabExtraData'
Assert-PatchMatch "restore stages identity before insertion" `
  'CreateRestoredTab[\s\S]{0,2500}StageRestoredPinId\(web_contents\.get\(\), extra_data\)[\s\S]{0,500}ToNavigationEntries'
Assert-PatchMatch "session restore defers reconciliation" `
  'SessionRestore::IsRestoring\(profile_\)'
Assert-PatchMatch "session restore completion callback" `
  'RegisterOnSessionRestoredCallback'
Assert-PatchMatch "actual restore identity coverage" `
  'PersistentPinIdentityRestoresBeforeTabInsertion'
Assert-PatchMatch "discard identity coverage" `
  'DiscardPreservesIdentityAndSessionExtraData'

Assert-PatchMatch "incognito excluded by factory" `
  'WithRegular\(ProfileSelection::kOriginalOnly\)'
Assert-PatchMatch "guest excluded by factory" `
  'WithGuest\(ProfileSelection::kNone\)'
Assert-PatchMatch "codec blocks ephemeral profiles" `
  '!profile->IsOffTheRecord\(\)[\s\S]+!profile->IsGuestSession\(\)'
Assert-PatchMatch "ephemeral-profile coverage" `
  'IncognitoHasNoPersistentPinServiceOrCodecState'

Assert-PatchMatch "explicit persistent removal route" `
  'void PinnedTabService::RemovePersistentPin'
Assert-PatchMatch "unpin is the deletion boundary" `
  'OnTabPinnedStateChanged[\s\S]+deletion boundary[\s\S]+RemoveRecordForTab'
Assert-PatchMatch "normal close only drops live binding" `
  'removed_persistent_pin \|= live_pin_ids_\.erase'
Assert-PatchMatch "shutdown retains and writes records" `
  'Shutdown\(\)[\s\S]+Shutdown is not an explicit removal route[\s\S]+WriteRecords\(\)'
Assert-PatchMatch "close versus unpin browser coverage" `
  'CloseRematerializesButExplicitUnpinRemoves'
Assert-PatchMatch "persistence tests use deterministic local navigation" `
  'CloseRematerializesButExplicitUnpinRemoves[\s\S]+embedded_test_server\(\)->GetURL[\s\S]+DiscardPreservesIdentityAndSessionExtraData[\s\S]+embedded_test_server\(\)->GetURL'
Assert-PatchDoesNotMatch "close path must not erase persistent records" `
  'change\.type\(\) == TabStripModelChange::kRemoved[\s\S]{0,1800}std::erase_if\(records_'

Assert-PatchDoesNotMatch "must not overlap tab-lifecycle command patch" `
  '(?m)^diff --git a/chrome/browser/ui/tabs/(tab_menu_model|tab_strip_model)\.(cc|h) b/'
Assert-PatchDoesNotMatch "must not carry raw favicon image data" `
  '(favicon_bytes|PNGCodec|SkBitmap)'
Assert-PatchDoesNotMatch "must not contain machine-specific source paths" `
  'C:\\src\\kwiken-chromium'
Assert-PatchDoesNotMatch "must not contain Git diagnostic output" `
  '(?m)^warning: in the working copy'

if ($failures.Count -gt 0) {
  throw "Persistent-pins patch contract failed:`n$($failures -join [Environment]::NewLine)"
}

Write-Output "Persistent-pins patch contract passed ($($actualFiles.Count) upstream files)."
