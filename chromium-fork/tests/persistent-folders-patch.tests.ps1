$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$patchPath = Join-Path (Split-Path -Parent $PSScriptRoot) `
  "patches\0005-kwiken-persistent-folders.patch"

if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
  throw "Persistent-folders patch is missing: $patchPath"
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

$expectedBaseBlobs = [ordered]@{
  "chrome/browser/ui/tabs/saved_tab_groups/local_tab_group_listener.cc" = "ac697c533405b018bd352296b14ca45b67b690b9"
  "chrome/browser/ui/tabs/saved_tab_groups/saved_tab_group_model_listener.cc" = "cdd4a4be2be426942dc682e8a3c5da8b9128033f"
  "chrome/browser/ui/tabs/saved_tab_groups/tab_group_sync_delegate_browsertest.cc" = "8dbfeb49c909dbcff0ca5d02fac5766167aaa047"
  "chrome/browser/ui/tabs/saved_tab_groups/tab_group_sync_delegate_desktop.cc" = "e7495c5e7d72f162b628b3984dca00e64f7deff3"
  "components/saved_tab_groups/internal/saved_tab_group_model.cc" = "57299c1a0441acb26b4c7710efb39d1fadd4e11c"
  "components/saved_tab_groups/internal/saved_tab_group_model_unittest.cc" = "f34b465c6fd8ddf8b61978df5aea692bc6495189"
  "components/saved_tab_groups/internal/saved_tab_group_proto_conversion_unittest.cc" = "965f9330f355e8afd870b619efdb9e8fd324049c"
  "components/saved_tab_groups/internal/saved_tab_group_proto_conversions.cc" = "5479150419cccbe14013e28dfd2ef8ec79a8350d"
  "components/saved_tab_groups/proto/local_tab_group_data.proto" = "5ebd5a4f44232f8e925850bddfd8e1ca1b54296a"
  "components/saved_tab_groups/public/saved_tab_group.cc" = "9f4dce4ab968145a5f5fa768ead4333fff973f35"
  "components/saved_tab_groups/public/saved_tab_group.h" = "a52ccb116c12ca060a81ad36ccba3a1dcccb5d1c"
}

$actualFiles = @(
  [regex]::Matches($patch, '(?m)^diff --git a/(.+?) b/') |
    ForEach-Object { $_.Groups[1].Value }
)
$unexpectedFiles = @(
  $actualFiles | Where-Object { -not $expectedBaseBlobs.Contains($_) }
)
$missingFiles = @(
  $expectedBaseBlobs.Keys | Where-Object { $_ -notin $actualFiles }
)
if ($unexpectedFiles.Count -gt 0) {
  $failures.Add("Patch touches unexpected files: $($unexpectedFiles -join ', ')")
}
if ($missingFiles.Count -gt 0) {
  $failures.Add("Patch omits expected files: $($missingFiles -join ', ')")
}

foreach ($path in $expectedBaseBlobs.Keys) {
  $escapedPath = [regex]::Escape($path)
  $match = [regex]::Match(
    $patch,
    "(?m)^diff --git a/$escapedPath b/$escapedPath\r?\nindex ([0-9a-f]{40})\.\.([0-9a-f]{40}) 100644$")
  if (-not $match.Success) {
    $failures.Add("$path does not carry full byte-identifying blob hashes")
    continue
  }
  if ($match.Groups[1].Value -ne $expectedBaseBlobs[$path]) {
    $failures.Add(
      "$path preimage mismatch: expected $($expectedBaseBlobs[$path]), got $($match.Groups[1].Value)")
  }
  if ($match.Groups[1].Value -eq $match.Groups[2].Value) {
    $failures.Add("$path has identical preimage and result blobs")
  }
}

Assert-PatchDoesNotMatch "upstream files only" '(?m)^(---|\+\+\+) /dev/null$'
Assert-PatchDoesNotMatch "local state never enters sync specifics" `
  '(?m)^diff --git a/.+saved_tab_group_specifics\.proto b/'
Assert-PatchDoesNotMatch "no lifecycle command overlap" `
  '(?m)^diff --git a/chrome/browser/ui/tabs/(tab_menu_model|tab_strip_model)\.(cc|h) b/'
Assert-PatchDoesNotMatch "no machine-specific source path" `
  'C:\\src\\kwiken-chromium'
Assert-PatchDoesNotMatch "no Git diagnostics" `
  '(?m)^warning: in the working copy'

# Local-only schema and lossless model conversion.
Assert-PatchMatch "local collapsed-state schema" `
  'LocalTabGroupData[\s\S]+optional bool is_collapsed = 9 \[default = false\]'
Assert-PatchMatch "SavedTabGroup collapsed getter" `
  'bool is_collapsed\(\) const \{ return is_collapsed_; \}'
Assert-PatchMatch "SavedTabGroup collapsed setter" `
  'SavedTabGroup& SavedTabGroup::SetIsCollapsed\(bool is_collapsed\)'
Assert-PatchMatch "local state is serialized" `
  'local_data->set_is_collapsed\(group\.is_collapsed\(\)\)'
Assert-PatchMatch "local state is deserialized" `
  'is_collapsed = data\.local_tab_group_data\(\)\.is_collapsed\(\)'
Assert-PatchMatch "clone preserves collapsed state" `
  'CopyBaseFieldsWithTabs\(\) const[\s\S]{0,180}SetIsCollapsed\(is_collapsed\(\)\)'
Assert-PatchMatch "round-trip conversion coverage" `
  'GroupToDataRetainsData[\s\S]+SetIsCollapsed\(true\)[\s\S]+local_tab_group_data\(\)\.is_collapsed\(\)'
Assert-PatchMatch "legacy records default expanded" `
  'MissingLocalCollapsedStateDefaultsToExpanded[\s\S]+EXPECT_FALSE\(group\.is_collapsed\(\)\)'

# Local visuals own collapse; sync owns only the shared title/color fields.
Assert-PatchMatch "local visual changes persist collapse" `
  'UpdateVisualDataLocally[\s\S]{0,500}SetIsCollapsed\(visual_data->is_collapsed\(\)\)'
Assert-PatchMatch "remote visuals preserve local collapse coverage" `
  'remote title/color update must not overwrite[\s\S]+UpdatedVisualDataFromSync[\s\S]+EXPECT_TRUE\(group->is_collapsed\(\)\)'
Assert-PatchMatch "new folders capture live collapse" `
  'CreateSavedTabGroupAndTabMapping[\s\S]+SetIsCollapsed\(tab_group->visual_data\(\)->is_collapsed\(\)\)'
Assert-PatchMatch "sync reconciliation restores saved collapse" `
  'ChangeTabGroupVisuals[\s\S]{0,250}saved_group->is_collapsed\(\)'
Assert-PatchMatch "folder reopening restores saved collapse" `
  'AddOpenedTabsToGroup[\s\S]+saved_group\.is_collapsed\(\)'
Assert-PatchMatch "close retains and reopen restores browser coverage" `
  'CollapsedStateRestoredWhenSavedFolderReopened[\s\S]+CloseAllTabsInGroup[\s\S]+!closed_group->local_group_id\(\)\.has_value\(\)[\s\S]+OpenTabGroup[\s\S]+EXPECT_TRUE\(reopened_group->visual_data\(\)->is_collapsed\(\)\)'

# Live drag ordering is projected into the profile-backed saved-folder order.
Assert-PatchMatch "moved folders reorder before their next neighbor" `
  'case TabGroupChange::kMoved[\s\S]+ReorderGroupBefore\(moved_group->saved_guid\(\),[\s\S]+next_saved_group->saved_guid\(\)\)'
Assert-PatchMatch "last moved folder reorders after its previous neighbor" `
  'ReorderGroupAfter\(moved_group->saved_guid\(\),[\s\S]+previous_saved_group->saved_guid\(\)\)'
Assert-PatchMatch "folder-order browser coverage" `
  'MovingLiveFolderPersistsSavedFolderOrder[\s\S]+MoveGroupTo\(third, 0\)[\s\S]+groups\[0\]\.saved_guid\(\) == third_guid'

if ($failures.Count -gt 0) {
  throw "Persistent-folders patch contract failed:`n$($failures -join [Environment]::NewLine)"
}

Write-Output `
  "Persistent-folders patch contract passed ($($actualFiles.Count) byte-pinned upstream files)."
