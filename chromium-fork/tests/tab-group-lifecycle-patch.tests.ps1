$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$patchPath = Join-Path (Split-Path -Parent $PSScriptRoot) `
  "patches\0004-kwiken-tab-group-lifecycle.patch"

if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
  throw "Tab-group lifecycle patch is missing: $patchPath"
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
  "chrome/app/generated_resources.grd",
  "chrome/browser/ui/views/tabs/groups/tab_group_editor_bubble_view.cc",
  "chrome/browser/ui/views/tabs/groups/tab_group_editor_bubble_view.h",
  "chrome/browser/ui/views/tabs/groups/tab_group_editor_bubble_view_browsertest.cc",
  "tools/metrics/actions/actions.xml",
  "tools/metrics/histograms/metadata/tab/histograms.xml"
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

Assert-PatchMatch "localized Load all tabs label" `
  'IDS_TAB_GROUP_HEADER_CXMENU_LOAD_ALL_TABS[\s\S]+Load all tabs'
Assert-PatchMatch "localized Unload all tabs label" `
  'IDS_TAB_GROUP_HEADER_CXMENU_UNLOAD_ALL_TABS[\s\S]+Unload all tabs'
Assert-PatchMatch "localized load accessibility description" `
  'IDS_TAB_GROUP_HEADER_CXMENU_LOAD_ALL_TABS_DESCRIPTION'
Assert-PatchMatch "localized unload accessibility description" `
  'IDS_TAB_GROUP_HEADER_CXMENU_UNLOAD_ALL_TABS_DESCRIPTION'
Assert-PatchMatch "localized load result description" `
  'IDS_TAB_GROUP_HEADER_CXMENU_LOAD_ALL_TABS_RESULT_DESCRIPTION'
Assert-PatchMatch "localized unload result description" `
  'IDS_TAB_GROUP_HEADER_CXMENU_UNLOAD_ALL_TABS_RESULT_DESCRIPTION'
Assert-PatchMatch "result is announced to accessibility APIs" `
  'SetDescription\(result\)[\s\S]+AnnounceText\(result\)'
Assert-PatchMatch "shared group editor exposes both commands" `
  'BuildLoadAllTabsButton\(\)[\s\S]+BuildUnloadAllTabsButton\(\)'
Assert-PatchMatch "stable group identity resolves current membership" `
  'GetCurrentGroupTabs\(\)[\s\S]{0,40}const[\s\S]+ContainsTabGroup\(group_\)[\s\S]+ListTabs\(\)'
Assert-PatchMatch "actions snapshot TabInterface members" `
  'const std::vector<tabs::TabInterface\*> tabs = GetCurrentGroupTabs\(\)'
Assert-PatchMatch "load command targets discarded members" `
  '!IsCurrentGroupMember\(tab\) \|\| !IsTabDiscarded\(tab\)'
Assert-PatchMatch "load command uses lifecycle API" `
  'lifecycle->LoadTab\(\)'
Assert-PatchMatch "load command has session-restore fallback" `
  'tab->LoadIfNeeded\(\)'
Assert-PatchMatch "unload command queries eligibility" `
  'lifecycle->CanUnloadTab\(\)'
Assert-PatchMatch "unload command rechecks atomically at execution" `
  'lifecycle->CanUnloadTab\(\) && lifecycle->UnloadTab\(\)'
Assert-PatchMatch "load command enabled by actionable member" `
  'CanLoadAllTabs\(\) const[\s\S]+IsTabDiscarded\(tab\)[\s\S]+return true'
Assert-PatchMatch "unload command enabled by actionable member" `
  'CanUnloadAllTabs\(\) const[\s\S]+CanUnloadTab\(\)[\s\S]+return true'
Assert-PatchMatch "attempted metrics" `
  'LoadAllTabs\.Attempted[\s\S]+UnloadAllTabs\.Attempted'
Assert-PatchMatch "succeeded metrics" `
  'LoadAllTabs\.Succeeded[\s\S]+UnloadAllTabs\.Succeeded'
Assert-PatchMatch "skipped metrics" `
  'LoadAllTabs\.Skipped[\s\S]+UnloadAllTabs\.Skipped'
Assert-PatchMatch "tokenized metrics metadata" `
  'TabGroups\.TabGroupBubble\.\{Action\}\.\{Outcome\}'
Assert-PatchMatch "user-action metadata for Load all tabs" `
  '<action name="TabGroups_TabGroupBubble_LoadAllTabs"'
Assert-PatchMatch "user-action metadata for Unload all tabs" `
  '<action name="TabGroups_TabGroupBubble_UnloadAllTabs"'
Assert-PatchMatch "collapsed all-discarded round-trip coverage" `
  'GroupLifecycleRoundTripPreservesCollapsedIdentity[\s\S]+is_collapsed=\*/true[\s\S]+PressButton\(unload_button\)[\s\S]+PressButton\(load_button\)'
Assert-PatchMatch "identity and session-state coverage" `
  'TabHandle[\s\S]+GetLastCommittedURL[\s\S]+IsPinned\(\)[\s\S]+IsSplit\(\)[\s\S]+selection_before'
Assert-PatchMatch "grouped-tab pin invariant coverage" `
  'GroupLifecycleRoundTripPreservesCollapsedIdentity[\s\S]+EXPECT_FALSE\(tab->IsPinned\(\)\)'
Assert-PatchMatch "group visual state coverage" `
  'TabGroupVisualData visual_data[\s\S]+GetTabGroup\(group_\.value\(\)\)[\s\S]+visual_data\(\)'
Assert-PatchMatch "mixed protected-member coverage" `
  'UnloadAllTabsSkipsProtectedMembers[\s\S]+AddToNewSplit[\s\S]+SetIsCurrentlyAudible\(true\)[\s\S]+OnIsCapturingVideoChanged'
Assert-PatchMatch "partial completion count coverage" `
  'UnloadAllTabs\.Succeeded", 1, 1[\s\S]+UnloadAllTabs\.Skipped", 4, 1'
Assert-PatchMatch "large-group coverage" `
  'UnloadAllTabsHandlesLargeGroup[\s\S]+kLargeGroupSize = 32'

Assert-PatchDoesNotMatch "must not use presentational discard-ring state" `
  'ShouldShowDiscardStatus'
Assert-PatchDoesNotMatch "must not synthesize WebContents" `
  '(WebContents::Create|make_unique<content::WebContents>)'
Assert-PatchDoesNotMatch "must not bypass lifecycle unload APIs" `
  '(DiscardWebContentsAt|DiscardTab\(|LifecycleUnitDiscardReason::EXTERNAL)'
Assert-PatchDoesNotMatch "must not mutate saved-group persistence" `
  '(SavedTabGroupModel|TabGroupSyncServiceImpl|SavedTabGroupTab)'
Assert-PatchDoesNotMatch "must not contain machine-specific source paths" `
  'C:\\src\\kwiken-chromium'
Assert-PatchDoesNotMatch "must not contain Git diagnostic output" `
  '(?m)^warning: in the working copy'

if ($failures.Count -gt 0) {
  throw "Tab-group lifecycle patch contract failed:`n$($failures -join [Environment]::NewLine)"
}

Write-Output "Tab-group lifecycle patch contract passed ($($actualFiles.Count) upstream files)."
