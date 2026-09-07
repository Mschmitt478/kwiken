$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$forkRoot = Split-Path -Parent $PSScriptRoot
$patchPath = Join-Path $forkRoot `
  "patches\0009-kwiken-m153-hardening.patch"

if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
  throw "M153 hardening patch is missing: $patchPath"
}

$patch = [IO.File]::ReadAllText($patchPath)
$failures = [Collections.Generic.List[string]]::new()

function Assert-TextMatch {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Text,
    [Parameter(Mandatory = $true)]
    [string]$Pattern
  )

  if ($Text -notmatch $Pattern) {
    $script:failures.Add("$Name (missing pattern: $Pattern)")
  }
}

function Assert-TextDoesNotMatch {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Text,
    [Parameter(Mandatory = $true)]
    [string]$Pattern
  )

  if ($Text -match $Pattern) {
    $script:failures.Add("$Name (forbidden pattern: $Pattern)")
  }
}

function Get-PatchSection {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $escapedPath = [regex]::Escape($Path)
  return [regex]::Match(
    $patch,
    "(?ms)^diff --git a/$escapedPath b/$escapedPath\r?\n.*?(?=^diff --git |\z)"
  ).Value
}

function Get-AddedLines {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Text
  )

  return @(
    $Text -split '\r?\n' |
      Where-Object { $_ -match '^\+(?!\+\+)' } |
      ForEach-Object { $_.Substring(1) }
  ) -join "`n"
}

function Get-RemovedLines {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Text
  )

  return @(
    $Text -split '\r?\n' |
      Where-Object { $_ -match '^-(?!---)' } |
      ForEach-Object { $_.Substring(1) }
  ) -join "`n"
}

function Assert-AddedMatch {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [string]$Pattern
  )

  Assert-TextMatch -Name $Name -Text $script:addedByPath[$Path] `
    -Pattern $Pattern
}

function Assert-AddedDoesNotMatch {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [string]$Pattern
  )

  Assert-TextDoesNotMatch -Name $Name -Text $script:addedByPath[$Path] `
    -Pattern $Pattern
}

$expectedBaseBlobs = [ordered]@{
  "build/toolchain/win/setup_toolchain.py" =
    "68ad6c4a009bdde1bfc907adedcfb2fdb7f7beb4"
  "chrome/browser/new_tab_page/modules/v2/tab_groups/tab_groups_page_handler_unittest.cc" =
    "12b42f22bf6e3b8b91b2370c3510bd04aac88cce"
  "chrome/browser/resource_coordinator/tab_lifecycle_unit.cc" =
    "19158556db57a2e7fd962a38d1377ee39421d19a"
  "chrome/browser/resource_coordinator/tab_lifecycle_unit_unittest.cc" =
    "b41d0d9a9084ca4a9e6483ec68072c200eb5b3e8"
  "chrome/browser/ui/startup/infobar_utils.cc" =
    "99dd32541ab26f549537b73366cce33f62679748"
  "chrome/browser/ui/tabs/BUILD.gn" =
    "2e07ee15fe90a3c679d23664ebd02ba22c314f6a"
  "chrome/browser/ui/tabs/pinned_tab_service.cc" =
    "b0f3b3b720e1aaeb228950d7fefa4cd8467a3cea"
  "chrome/browser/ui/tabs/pinned_tab_service.h" =
    "ffb0742c8749c4d5344bda521747df8c808df265"
  "chrome/browser/ui/tabs/pinned_tab_service_browsertest.cc" =
    "69ad85d5699bcc5745fb33e6a7619639f4f9d30d"
  "chrome/browser/ui/tabs/saved_tab_groups/saved_tab_group_model_listener.cc" =
    "fb34f2f35cb5957edfd7fcf22552dbf1c425fae2"
  "chrome/browser/ui/tabs/saved_tab_groups/tab_group_sync_delegate_browsertest.cc" =
    "908bcc33daccdcaaf6d8ffc03103ce25aef9c4d3"
  "chrome/browser/ui/tabs/tab_data.cc" =
    "1f01557a58f63c1f7aefbba2fd5176935b98ef41"
  "chrome/browser/ui/tabs/tab_data_browsertest.cc" =
    "c4c3b61ffc24f4b8c4577435c07ac9c97aacf5f2"
  "chrome/browser/ui/views/tabs/common/split_tab_view.cc" =
    "c65ab3ed4cb7265a93fecc90f6d78e97d0be56ba"
  "chrome/browser/ui/views/tabs/common/split_tab_view_browsertest.cc" =
    "52168531dc2708e6da58bc164fd958ac9446395e"
  "components/saved_tab_groups/internal/saved_tab_group_model.cc" =
    "0f8b402887879806107bca42996a1abd752d35dc"
  "components/saved_tab_groups/internal/saved_tab_group_model.h" =
    "cc1c870748d9956b1e2a4eb715415189a8b118b0"
  "components/saved_tab_groups/internal/saved_tab_group_model_unittest.cc" =
    "b1554ec6c6fba30497ccdd88b82fd0ad216e3f96"
  "components/saved_tab_groups/internal/shared_tab_group_data_sync_bridge.cc" =
    "5f15f4ea34310069f302cbdb30f7d205f0472dfd"
  "components/saved_tab_groups/internal/shared_tab_group_data_sync_bridge_unittest.cc" =
    "8737352d79901dbb43a324a431926a0c04bfa085"
  "components/saved_tab_groups/internal/tab_group_sync_service_impl.cc" =
    "b86cb48d446676b75af90d529920e8e857889f09"
  "components/saved_tab_groups/internal/tab_group_sync_service_impl.h" =
    "206d02acdd81e9edc1e9ade4bbeac06e05fdb5fd"
  "components/saved_tab_groups/proto/shared_tab_group_data.proto" =
    "50acea92aa1ef1adcefd81edc2e7b73a55ca7666"
  "components/saved_tab_groups/public/tab_group_sync_service.h" =
    "3f55d362d60cbc9743f8020946c5d3b9e639f2d1"
  "components/saved_tab_groups/test_support/fake_tab_group_sync_service.cc" =
    "77e6f2bd95560fc4a717e019c811ae4da66f5f03"
  "components/saved_tab_groups/test_support/fake_tab_group_sync_service.h" =
    "7849657a48d5c99ba675cf3c11a9384c9a0860b6"
  "components/saved_tab_groups/test_support/mock_tab_group_sync_service.h" =
    "90c62f24d0914bd4736322009fef01293a4d4263"
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
$duplicateFiles = @(
  $actualFiles | Group-Object | Where-Object { $_.Count -gt 1 }
)
if ($actualFiles.Count -ne $expectedBaseBlobs.Count) {
  $failures.Add(
    "Patch must touch exactly $($expectedBaseBlobs.Count) files, got $($actualFiles.Count)"
  )
}
if ($unexpectedFiles.Count -gt 0) {
  $failures.Add("Patch touches unexpected files: $($unexpectedFiles -join ', ')")
}
if ($missingFiles.Count -gt 0) {
  $failures.Add("Patch omits expected files: $($missingFiles -join ', ')")
}
if ($duplicateFiles.Count -gt 0) {
  $failures.Add(
    "Patch repeats file sections: $($duplicateFiles.Name -join ', ')"
  )
}

$script:addedByPath = @{}
$removedByPath = @{}
foreach ($path in $expectedBaseBlobs.Keys) {
  $escapedPath = [regex]::Escape($path)
  $match = [regex]::Match(
    $patch,
    "(?m)^diff --git a/$escapedPath b/$escapedPath\r?\nindex ([0-9a-f]{40})\.\.([0-9a-f]{40}) 100644$"
  )
  if (-not $match.Success) {
    $failures.Add("$path does not carry full byte-identifying blob hashes")
    continue
  }
  if ($match.Groups[1].Value -ne $expectedBaseBlobs[$path]) {
    $failures.Add(
      "$path preimage mismatch: expected $($expectedBaseBlobs[$path]), got $($match.Groups[1].Value)"
    )
  }
  if ($match.Groups[1].Value -eq $match.Groups[2].Value) {
    $failures.Add("$path has identical preimage and result blobs")
  }

  $section = Get-PatchSection -Path $path
  if ([string]::IsNullOrEmpty($section)) {
    $failures.Add("$path has no readable patch section")
    continue
  }
  $script:addedByPath[$path] = Get-AddedLines -Text $section
  $removedByPath[$path] = Get-RemovedLines -Text $section
}

Assert-TextDoesNotMatch "upstream files only" $patch `
  '(?m)^(---|\+\+\+) /dev/null$'
Assert-TextDoesNotMatch "no machine-specific source paths" $patch `
  '(?i)C:[\\/]src[\\/]'
Assert-TextDoesNotMatch "no Git diagnostics" $patch `
  '(?m)^warning: in the working copy'
Assert-TextDoesNotMatch "no merge conflict markers" $patch `
  '(?m)^[+-](?:<<<<<<<|=======|>>>>>>>)'

$toolchain = "build/toolchain/win/setup_toolchain.py"
Assert-AddedMatch $toolchain "subprocess environment injection" `
  'def _LoadEnvFromBat\(args, env=None\):[\s\S]+env=env'
Assert-AddedMatch $toolchain "complete extracted SDK environment" `
  'def _WindowsSdkEnvironment[\s\S]+WindowsSdkDir[\s\S]+WindowsSDKVersion[\s\S]+WindowsSdkLibVersion[\s\S]+WindowsSdkBinPath[\s\S]+WindowsSdkVerBinPath[\s\S]+UniversalCRTSdkDir[\s\S]+UCRTVersion'
Assert-AddedMatch $toolchain "normalized non-default SDK detection" `
  '_UsesNonDefaultWindowsSdk[\s\S]+ProgramFiles\(x86\)[\s\S]+Windows Kits[\\/]10[\s\S]+normcase[\s\S]+abspath'
Assert-AddedMatch $toolchain "supported no-install Visual Studio entrypoint" `
  'Common7/Tools/VsDevCmd\.bat[\s\S]+os\.path\.exists[\s\S]+-arch=[\s\S]+-host_arch=x64[\s\S]+-winsdk=none'
Assert-AddedMatch $toolchain "case-insensitive inherited SDK cleanup" `
  'sdk_environment = os\.environ\.copy\(\)[\s\S]+for name in explicit_sdk_environment[\s\S]+existing_name\.lower\(\) == name\.lower\(\)[\s\S]+del sdk_environment\[existing_name\][\s\S]+sdk_environment\.update'
Assert-AddedMatch $toolchain "UWP mapping for explicit SDK" `
  "target_store[\s\S]+args\.append\('-app_platform=UWP'\)"
Assert-AddedMatch $toolchain "explicit SDK remains subprocess-local" `
  '_LoadEnvFromBat\(args, env=sdk_environment\)'
Assert-AddedMatch $toolchain "default vcvarsall behavior retained" `
  "script_path[\s\S]+cpu_arg[\s\S]+args\.append\('store'\)[\s\S]+args\.append\(SDK_VERSION\)[\s\S]+_LoadEnvFromBat\(args\)"
Assert-AddedDoesNotMatch $toolchain "must not mutate process environment" `
  'os\.(?:environ\.update|putenv)'

$lifecycle = "chrome/browser/resource_coordinator/tab_lifecycle_unit.cc"
Assert-AddedMatch $lifecycle "connected-device unload protection" `
  'IsConnectedToUSBDevice[\s\S]+IsConnectedToBluetoothDevice[\s\S]+IsConnectedToHidDevice[\s\S]+IsConnectedToSerialPort'
Assert-AddedMatch $lifecycle "PiP and PDF unload protection" `
  'HasPictureInPictureVideo[\s\S]+HasPictureInPictureDocument[\s\S]+GetContentsMimeType\(\) == "application/pdf"'
Assert-AddedMatch $lifecycle "non-form user-edit unload protection" `
  'PerformanceManager::IsAvailable\(\)[\s\S]+GetPrimaryPageNodeForWebContents[\s\S]+page_node->HadUserEdits\(\)'

$lifecycleTest =
  "chrome/browser/resource_coordinator/tab_lifecycle_unit_unittest.cc"
Assert-AddedMatch $lifecycleTest "connected-device regression coverage" `
  'UserUnloadRejectsConnectedDevices[\s\S]+kUSB[\s\S]+kBluetoothConnected[\s\S]+kHID[\s\S]+kSerial'
Assert-AddedMatch $lifecycleTest "PiP and PDF regression coverage" `
  'UserUnloadRejectsPictureInPictureAndPdf[\s\S]+SetHasPictureInPictureDocument\(true\)[\s\S]+SetMainFrameMimeType\("application/pdf"\)'
Assert-AddedMatch $lifecycleTest "user-edit regression coverage" `
  'UserUnloadRejectsUserEdits[\s\S]+SetHadUserEditsForTesting\(true\)[\s\S]+EXPECT_FALSE\(tab_lifecycle_unit\.CanUnloadTab\(\)\)[\s\S]+EXPECT_FALSE\(tab_lifecycle_unit\.UnloadTab\(\)\)'

$infobar = "chrome/browser/ui/startup/infobar_utils.cc"
Assert-TextMatch "obsolete conflict include is removed" $removedByPath[$infobar] `
  'bidding_and_auction_consented_debugging_infobar_delegate\.h'
Assert-AddedDoesNotMatch $infobar "obsolete conflict include is not re-added" `
  'bidding_and_auction_consented_debugging_infobar_delegate\.h'

$pinService = "chrome/browser/ui/tabs/pinned_tab_service.cc"
$pinHeader = "chrome/browser/ui/tabs/pinned_tab_service.h"
$pinTest = "chrome/browser/ui/tabs/pinned_tab_service_browsertest.cc"
$pinBuild = "chrome/browser/ui/tabs/BUILD.gn"
Assert-AddedMatch $pinHeader "close-cancellation callback contract" `
  'OnBrowserCloseCancelled[\s\S]+ClosingStatus'
Assert-AddedMatch $pinHeader "close-cancellation subscription ownership" `
  'flat_map<raw_ptr<TabStripModel>, base::CallbackListSubscription>[\s\S]+browser_close_cancelled_subscriptions_'
Assert-AddedMatch $pinService "weak close-cancellation registration" `
  'RegisterBrowserCloseCancelled[\s\S]+BindRepeating[\s\S]+OnBrowserCloseCancelled[\s\S]+weak_factory_\.GetWeakPtr'
Assert-AddedMatch $pinService "true cancellation resumes reconciliation" `
  'OnBrowserCloseCancelled[\s\S]+kPermitted[\s\S]+kDeniedUnloadHandlersNeedTime[\s\S]+closing_models_\.erase[\s\S]+ScheduleReconcile'
Assert-AddedMatch $pinService "stale global-close state is pruned" `
  'for \(auto it = closing_models_\.begin\(\)[\s\S]+FindBrowserForModel[\s\S]+IsAttemptingToCloseBrowser[\s\S]+closing_models_\.erase'
Assert-AddedMatch $pinService "interrupted close-all is state-aware" `
  'reason == kCloseAllCompleted[\s\S]+FindBrowserForModel\(tab_strip_model\)[\s\S]+IsAttemptingToCloseBrowser'
$closingModelFilters = [regex]::Matches(
  $script:addedByPath[$pinService],
  'IsDeleteScheduled\(\)[\s\S]{0,160}closing_models_\.contains[\s\S]{0,160}IsAttemptingToCloseBrowser'
).Count
if ($closingModelFilters -ne 2) {
  $failures.Add(
    "Restore targeting and reconciliation must both exclude closing models"
  )
}
Assert-AddedMatch $pinService "shutdown clears close subscriptions" `
  'browser_close_cancelled_subscriptions_\.clear\(\)'
$subscriptionErases = [regex]::Matches(
  $script:addedByPath[$pinService],
  'browser_close_cancelled_subscriptions_\.erase'
).Count
if ($subscriptionErases -lt 2) {
  $failures.Add(
    "Browser close and model destruction must both release subscriptions"
  )
}
Assert-AddedMatch $pinTest "deferred-close regression coverage" `
  'DeferredCloseDoesNotRematerializePinUntilCancelled[\s\S]+onbeforeunload[\s\S]+GetWindow\(\)->Close\(\)[\s\S]+IsAttemptingToCloseBrowser[\s\S]+CloseAllTabs\(\)[\s\S]+WaitForAppModalDialog[\s\S]+ASSERT_EQ\(1, model->count\(\)\)[\s\S]+OnCancel[\s\S]+ASSERT_EQ\(2, model->count\(\)\)[\s\S]+IsTabPinned\(0\)'
Assert-AddedMatch $pinTest "deferred-close test owns complete API headers" `
  'desktop_browser_window_capabilities\.h[\s\S]+browser_test_utils\.h'
Assert-AddedMatch $pinBuild "deferred-close test owns dialog dependency" `
  '//components/javascript_dialogs'

$tabData = "chrome/browser/ui/tabs/tab_data.cc"
$tabDataTest = "chrome/browser/ui/tabs/tab_data_browsertest.cc"
Assert-AddedMatch $tabData "durable-only discarded status" `
  'ShouldShowDiscardStatus\(\) \|\|[\s\S]+is_tab_discarded[\s\S]+IsPinned\(\) \|\| tab_interface->GetGroup\(\)\.has_value\(\)'
Assert-AddedDoesNotMatch $tabData "ordinary discard is not promoted" `
  'ShouldShowDiscardStatus\(\) \|\|\s*tab_data\.is_tab_discarded\s*;'
Assert-AddedMatch $tabDataTest "ordinary versus pinned discard coverage" `
  'EXPECT_FALSE\(data_restored_unloaded\.should_show_discard_status\)[\s\S]+SetTabPinned\(0, true\)[\s\S]+EXPECT_TRUE\(data_pinned_unloaded\.should_show_discard_status\)'

$split = "chrome/browser/ui/views/tabs/common/split_tab_view.cc"
$splitTest =
  "chrome/browser/ui/views/tabs/common/split_tab_view_browsertest.cc"
Assert-AddedMatch $split "horizontal split border stays one DIP" `
  'kHorizontalPinnedSplitBorderThickness = 1[\s\S]+kHorizontalPinnedSplitBorderThickness,'
Assert-AddedDoesNotMatch $split "horizontal split does not use vertical border" `
  'kVerticalTabPinnedBorderThickness'
Assert-AddedMatch $splitTest "horizontal split border regression coverage" `
  'HorizontalPinnedSplitKeepsUpstreamBorderThickness[\s\S]+ExitVerticalTabsMode\(\)[\s\S]+AppendPinnedTab[\s\S]+AddToNewSplit[\s\S]+UpdateBorder\(\)[\s\S]+EXPECT_EQ\(gfx::Insets\(1\), split_tab_view->GetInsets\(\)\)'

$sharedProto =
  "components/saved_tab_groups/proto/shared_tab_group_data.proto"
$sharedBridge =
  "components/saved_tab_groups/internal/shared_tab_group_data_sync_bridge.cc"
$sharedBridgeTest =
  "components/saved_tab_groups/internal/shared_tab_group_data_sync_bridge_unittest.cc"
Assert-AddedMatch $sharedProto "shared collapse remains local-only field 9" `
  'presentation state for this profile/device[\s\S]+optional bool is_collapsed = 9 \[default = false\]'
Assert-AddedMatch $sharedBridge "shared collapse loads from local data" `
  'has_is_collapsed\(\)[\s\S]+SetIsCollapsed\([\s\S]+is_collapsed\(\)'
Assert-AddedMatch $sharedBridge "shared collapse writes to local data" `
  'set_is_collapsed\(group\.is_collapsed\(\)\)'
Assert-AddedMatch $sharedBridgeTest "shared collapse restart coverage" `
  'SetIsCollapsed\(true\)[\s\S]+EXPECT_TRUE\(model\(\)->saved_tab_groups\(\)\.front\(\)\.is_collapsed\(\)\)'

$listener =
  "chrome/browser/ui/tabs/saved_tab_groups/saved_tab_group_model_listener.cc"
Assert-AddedMatch $listener "moved shared and unpinned groups are ignored" `
  'moved_group->is_shared_tab_group\(\)[\s\S]+!moved_group->is_pinned\(\)'
Assert-AddedMatch $listener "live visual order is collected" `
  'ordered_group_ids[\s\S]+previous_local_group_id[\s\S]+index < change\.model->count\(\)[\s\S]+local_group_id =[\s\S]+local_group_id == previous_local_group_id'
Assert-AddedMatch $listener "only regular pinned neighbors participate" `
  '!saved_group->is_shared_tab_group\(\)[\s\S]+saved_group->is_pinned\(\)[\s\S]+ordered_group_ids\.push_back'
Assert-AddedMatch $listener "listener invokes atomic slot reorder" `
  'service_->ReorderGroupsInCurrentSlots\(ordered_group_ids\)'
Assert-AddedDoesNotMatch $listener "listener does not use displacing reorder APIs" `
  'ReorderGroup(?:Before|After)'

$atomicApiFiles = @(
  "components/saved_tab_groups/public/tab_group_sync_service.h",
  "components/saved_tab_groups/internal/tab_group_sync_service_impl.h",
  "components/saved_tab_groups/internal/tab_group_sync_service_impl.cc",
  "components/saved_tab_groups/internal/saved_tab_group_model.h",
  "components/saved_tab_groups/test_support/fake_tab_group_sync_service.h",
  "components/saved_tab_groups/test_support/fake_tab_group_sync_service.cc",
  "components/saved_tab_groups/test_support/mock_tab_group_sync_service.h"
)
foreach ($path in $atomicApiFiles) {
  Assert-AddedMatch $path "atomic reorder API is wired through $path" `
    'ReorderGroupsInCurrentSlots'
}

$newTabPageMock =
  "chrome/browser/new_tab_page/modules/v2/tab_groups/tab_groups_page_handler_unittest.cc"
Assert-AddedMatch $newTabPageMock "NTP tab-group mock tracks atomic reorder API" `
  'MOCK_METHOD\(void,[\s\S]+ReorderGroupsInCurrentSlots[\s\S]+ordered_group_ids'

$model = "components/saved_tab_groups/internal/saved_tab_group_model.cc"
$modelTest =
  "components/saved_tab_groups/internal/saved_tab_group_model_unittest.cc"
Assert-AddedMatch $model "atomic reorder validates before mutation" `
  'ordered_group_ids\.size\(\) < 2u[\s\S]+std::find[\s\S]+GetIndexOf[\s\S]+!index\.has_value\(\)[\s\S]+is_shared_tab_group\(\) \|\| !group\.is_pinned\(\)'
Assert-AddedMatch $model "atomic reorder sorts occupied slots" `
  'target_indices = source_indices[\s\S]+ranges::sort\(target_indices\)[\s\S]+source_indices == target_indices'
Assert-AddedMatch $model "atomic reorder moves only selected slots" `
  'ordered_groups\.push_back\(std::move\(saved_tab_groups_\[source_index\]\)\)[\s\S]+saved_tab_groups_\[target_indices\[i\]\] = std::move\(ordered_groups\[i\]\)'
Assert-AddedMatch $model "atomic reorder refreshes persisted positions" `
  'UpdateGroupPositionsImpl\(\)'
$reorderNotifications = [regex]::Matches(
  $script:addedByPath[$model],
  'observer\.SavedTabGroupReorderedLocally\(\);'
).Count
if ($reorderNotifications -ne 1) {
  $failures.Add(
    "Atomic reorder must emit exactly one local reorder notification, got $reorderNotifications"
  )
}
Assert-AddedMatch $modelTest "excluded slots and invalid input coverage" `
  'ReorderGroupsInCurrentSlotsPreservesExcludedGroupSlots[\s\S]+ElementsAre\(third_id, closed_id, first_id, second_id,[\s\S]+shared_id[\s\S]+unpinned_id[\s\S]+first_id, first_id'
Assert-AddedMatch $modelTest "single-notification and no-op coverage" `
  'ReorderGroupsInCurrentSlotsNotifiesOnce[\s\S]+EXPECT_EQ\(1, reordered_call_count_\)[\s\S]+ClearSignals\(\)[\s\S]+EXPECT_EQ\(0, reordered_call_count_\)'

$folderBrowserTest =
  "chrome/browser/ui/tabs/saved_tab_groups/tab_group_sync_delegate_browsertest.cc"
Assert-AddedMatch $folderBrowserTest "closed folder slot browser coverage" `
  'MovingLiveFolderPreservesClosedFolderSlot[\s\S]+CloseAllTabsInGroup\(closed\)[\s\S]+!group->local_group_id\(\)\.has_value\(\)[\s\S]+MoveGroupTo\(third, 0\)[\s\S]+groups\[0\]\.saved_guid\(\) == third_guid[\s\S]+groups\[1\]\.saved_guid\(\) == closed_guid[\s\S]+groups\[2\]\.saved_guid\(\) == first_guid[\s\S]+groups\[3\]\.saved_guid\(\) == second_guid'

if ($failures.Count -gt 0) {
  throw "M153 hardening patch contract failed:`n$($failures -join [Environment]::NewLine)"
}

Write-Output `
  "M153 hardening patch contract passed ($($actualFiles.Count) byte-pinned upstream files)."
