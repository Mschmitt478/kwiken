$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$patchPath = Join-Path (Split-Path -Parent $PSScriptRoot) `
  "patches\0002-kwiken-tab-lifecycle.patch"

if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
  throw "Lifecycle patch is missing: $patchPath"
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
  "chrome/browser/resource_coordinator/tab_lifecycle_unit.cc",
  "chrome/browser/resource_coordinator/tab_lifecycle_unit.h",
  "chrome/browser/resource_coordinator/tab_lifecycle_unit_external.h",
  "chrome/browser/resource_coordinator/tab_lifecycle_unit_unittest.cc",
  "chrome/browser/ui/tabs/tab_menu_model.cc",
  "chrome/browser/ui/tabs/tab_menu_model_browsertest.cc",
  "chrome/browser/ui/tabs/tab_strip_model.cc",
  "chrome/browser/ui/tabs/tab_strip_model.h",
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

Assert-PatchMatch "localized Load Tab label" `
  'IDS_TAB_CXMENU_LOAD_TAB'
Assert-PatchMatch "localized Unload Tab label" `
  'IDS_TAB_CXMENU_UNLOAD_TAB'
Assert-PatchMatch "shared context commands" `
  'CommandLoadTab[\s\S]+CommandUnloadTab'
Assert-PatchMatch "existing context command IDs stay stable" `
  'CommandGlicUnshare,[\s\S]+CommandLoadTab,[\s\S]+CommandUnloadTab,[\s\S]+CommandLast'
Assert-PatchMatch "actual discard-state signal" `
  'TabUIHelper::From\(tab\)'
Assert-PatchMatch "durable-tab scope includes pins and groups" `
  'bool IsPersistentTab\(tabs::TabInterface\* tab\)[\s\S]+tab->IsPinned\(\) \|\| tab->GetGroup\(\)\.has_value\(\)'
Assert-PatchMatch "menu hides lifecycle commands for ordinary context tabs" `
  'if \(IsPersistentTab\(tab_strip_->GetTabAtIndex\(index\)\)\)[\s\S]+if \(!IsPersistentTab\(tab\)\)'
Assert-PatchMatch "command enablement rejects ordinary context tabs" `
  'case CommandLoadTab: \{[\s\S]+!IsPersistentTab\(GetTabAtIndex\(context_index\)\)[\s\S]+IsPersistentTab\(tab\) && IsTabDiscarded\(tab\)'
Assert-PatchMatch "unload enablement ignores ordinary selected tabs" `
  'case CommandUnloadTab: \{[\s\S]+!IsPersistentTab\(GetTabAtIndex\(context_index\)\)[\s\S]+if \(!IsPersistentTab\(tab\)\)[\s\S]+lifecycle->CanUnloadTab\(\)'
Assert-PatchMatch "execution filters mixed selections to durable tabs" `
  'std::vector<tabs::TabInterface\*> command_tabs;[\s\S]+if \(IsPersistentTab\(tab\)\)[\s\S]+command_tabs\.push_back\(tab\)'
$durableSelectionFilters = [regex]::Matches(
  $patch,
  'std::vector<tabs::TabInterface\*> command_tabs;'
)
if ($durableSelectionFilters.Count -lt 2) {
  $failures.Add(
    "Load and Unload must each filter mixed selections to durable tabs"
  )
}
Assert-PatchMatch "explicit unload eligibility API" `
  'virtual bool CanUnloadTab\(\) const = 0'
Assert-PatchMatch "atomic unload API" `
  'virtual bool UnloadTab\(\) = 0'
Assert-PatchMatch "menu queries the lifecycle safety gate" `
  'lifecycle->CanUnloadTab\(\)'
Assert-PatchMatch "execution rechecks the lifecycle safety gate" `
  'return CanUnloadTab\(\) &&[\s\S]+LifecycleUnitDiscardReason::EXTERNAL'
Assert-PatchMatch "active and visible tabs are protected" `
  'active_index\(\)[\s\S]+IsVisible\(\)'
Assert-PatchMatch "current and recently audible tabs are protected" `
  'IsCurrentlyAudible\(\)[\s\S]+was_recently_audible'
Assert-PatchMatch "capture and mirroring are protected" `
  'IsCapturingVideo[\s\S]+IsCapturingAudio[\s\S]+IsBeingMirrored[\s\S]+IsCapturingWindow[\s\S]+IsCapturingDisplay'
Assert-PatchMatch "form interaction is protected" `
  'had_form_interaction\(\)'
Assert-PatchMatch "DevTools is protected" `
  'IsDevToolsOpen\(contents\)'
Assert-PatchMatch "auto-discard opt-out is protected" `
  'is_discarded_ \|\| !auto_discardable_'
Assert-PatchMatch "unloaded and beforeunload-sensitive tabs are protected" `
  'IsRenderFrameLive\(\)[\s\S]+NeedToFireBeforeUnloadOrUnloadEvents\(\)'
Assert-PatchMatch "explicit lifecycle load API" `
  'TabLifecycleUnitExternal[\s\S]+virtual bool LoadTab\(\) = 0'
Assert-PatchMatch "load command uses lifecycle API" `
  'lifecycle->LoadTab\(\)'
Assert-PatchMatch "session-restore fallback uses TabInterface" `
  'tab->LoadIfNeeded\(\)'
Assert-PatchMatch "legacy discard coverage" `
  'AutoDiscardablePersistsThroughDiscard[\s\S]+LoadTab\(\)'
Assert-PatchMatch "WebContents-discard coverage" `
  'InitAndEnableFeature\(features::kWebContentsDiscard\)'
Assert-PatchMatch "active-tab safety coverage" `
  'UserUnloadRejectsActiveOrVisibleTab'
Assert-PatchMatch "crashed-renderer safety coverage" `
  'UserUnloadRejectsCrashedRenderer[\s\S]+SetIsCrashed'
Assert-PatchMatch "beforeunload browser safety coverage" `
  'LifecycleCommandRejectsBeforeUnloadTab[\s\S]+ExecJs[\s\S]+NeedToFireBeforeUnloadOrUnloadEvents'
Assert-PatchMatch "AddTabAt browser helper declaration" `
  '#include "chrome/browser/ui/browser_tabstrip\.h"'
Assert-PatchMatch "ordinary-tab menu suppression coverage" `
  'LifecycleCommandsAreHiddenForOrdinaryTab[\s\S]+ASSERT_FALSE\(active_tab->IsPinned\(\)\)[\s\S]+CommandUnloadTab[\s\S]+CommandLoadTab'
Assert-PatchMatch "active-tab coverage uses durable scope" `
  'LifecycleCommandDoesNotUnloadActiveTab[\s\S]+SetTabPinned[\s\S]+ASSERT_TRUE\(active_tab->IsPinned\(\)\)'
Assert-PatchMatch "beforeunload coverage uses durable scope" `
  'LifecycleCommandRejectsBeforeUnloadTab[\s\S]+SetTabPinned[\s\S]+ASSERT_TRUE\(protected_tab->IsPinned\(\)\)'
Assert-PatchMatch "audibility safety coverage" `
  'UserUnloadRejectsCurrentAndRecentAudio'
Assert-PatchMatch "capture safety coverage" `
  'UserUnloadRejectsMediaCaptureAndMirroring'
Assert-PatchMatch "form safety coverage" `
  'UserUnloadRejectsFormInteraction'
Assert-PatchMatch "selected pinned-tab browser coverage" `
  'LifecycleCommandsHandleSelectionAndPreservePinnedTabIdentity'
Assert-PatchMatch "group-membership browser coverage" `
  'LifecycleCommandsPreserveTabGroupMembership'
Assert-PatchMatch "metrics metadata for Load Tab" `
  '<variant name="LoadTab"'
Assert-PatchMatch "metrics metadata for Unload Tab" `
  '<variant name="UnloadTab"'
Assert-PatchMatch "user-action metadata for Load Tab" `
  '<action name="TabContextMenu_LoadTab"'
Assert-PatchMatch "user-action metadata for Unload Tab" `
  '<action name="TabContextMenu_UnloadTab"'

Assert-PatchDoesNotMatch "must not synthesize WebContents" `
  '(WebContents::Create|make_unique<content::WebContents>)'
Assert-PatchDoesNotMatch "must not bypass the user-unload safety gate" `
  'tab_list->DiscardTab\(tab->GetHandle\(\)\)'
Assert-PatchDoesNotMatch "must not contain machine-specific source paths" `
  'C:\\src\\kwiken-chromium'
Assert-PatchDoesNotMatch "must not contain Git diagnostic output" `
  '(?m)^warning: in the working copy'

if ($failures.Count -gt 0) {
  throw "Tab-lifecycle patch contract failed:`n$($failures -join [Environment]::NewLine)"
}

Write-Output "Tab-lifecycle patch contract passed ($($actualFiles.Count) upstream files)."
