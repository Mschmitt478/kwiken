$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$forkRoot = Split-Path -Parent $PSScriptRoot
$patchPath = Join-Path $forkRoot "patches\0006-kwiken-zen-rail.patch"
$themePatchPath = Join-Path $forkRoot `
  "patches\0007-kwiken-theme-aware-palette.patch"
$brandPatchPath = Join-Path $forkRoot "patches\0001-kwiken-browser.patch"

foreach ($requiredPath in @($patchPath, $themePatchPath, $brandPatchPath)) {
  if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    throw "Required patch is missing: $requiredPath"
  }
}

$patch = [IO.File]::ReadAllText($patchPath)
$themePatch = [IO.File]::ReadAllText($themePatchPath)
$brandPatch = [IO.File]::ReadAllText($brandPatchPath)
$themeMixerPatch = [regex]::Match(
  $themePatch,
  '(?s)diff --git a/chrome/browser/ui/color/chrome_color_mixers\.cc .*?(?=\ndiff --git |\z)'
).Value
$failures = [Collections.Generic.List[string]]::new()

function Assert-TextMatch {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [string]$Text,
    [Parameter(Mandatory = $true)]
    [string]$Pattern
  )

  if ($Text -notmatch $Pattern) {
    $script:failures.Add("$Name (missing pattern: $Pattern)")
  }
}

function Assert-PatchMatch {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [string]$Pattern
  )

  Assert-TextMatch -Name $Name -Text $patch -Pattern $Pattern
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

function Assert-ThemePatchMatch {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [string]$Pattern
  )

  Assert-TextMatch -Name $Name -Text $themePatch -Pattern $Pattern
}

function Assert-ThemePatchDoesNotMatch {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [string]$Pattern
  )

  if ($themePatch -match $Pattern) {
    $script:failures.Add("$Name (forbidden pattern: $Pattern)")
  }
}

function Assert-ThemeMixerDoesNotMatch {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [string]$Pattern
  )

  if ($themeMixerPatch -match $Pattern) {
    $script:failures.Add("$Name (forbidden mixer pattern: $Pattern)")
  }
}

$expectedBaseBlobs = [ordered]@{
  "chrome/browser/ui/color/chrome_color_mixers.cc" = "8131056e212956decf4831730d1ab513a6c6afa4"
  "chrome/browser/ui/layout_constants.cc" = "a8b7ef68008b132ec786b91ddcb232c16a0c5750"
  "chrome/browser/ui/tab_ui_helper.cc" = "17dc6e180456b614c57cd034c34391efbba537d4"
  "chrome/browser/ui/tabs/tab_data.cc" = "5056be27f3b1fec30597ecbf8eb51fdbc5765dba"
  "chrome/browser/ui/tabs/tab_data_browsertest.cc" = "bba72e28b519dadad4ad6bbef215f4bea9cfe3be"
  "chrome/browser/ui/views/tabs/common/BUILD.gn" = "9354e0d5497b85db204ebae5d6adcd41973ea01a"
  "chrome/browser/ui/views/tabs/common/pinned_tab_container_view.cc" = "af4cd825d4c10c6b0802cf4134a902dd7346e9b8"
  "chrome/browser/ui/views/tabs/common/split_tab_view.cc" = "440a3076e5f80c6b393dba0b311ba15ea808681e"
  "chrome/browser/ui/views/tabs/common/split_tab_view.h" = "f380ec9050e75093b4380547314103f545fc6a4b"
  "chrome/browser/ui/views/tabs/common/tab_group_header_view.cc" = "cfaf18f54f721f3f4bf0eb438454e3e41f963728"
  "chrome/browser/ui/views/tabs/common/tab_group_header_view.h" = "982370f7cdb149a28adf1d5daaf2489741fb2618"
  "chrome/browser/ui/views/tabs/common/tab_strip_link_drag_browsertest.cc" = "7355525fbfb97dc729232ea8518b2e67eb5e9456"
  "chrome/browser/ui/views/tabs/common/tab_strip_view_layout.cc" = "db53e40e591295311569835fae59eb340ad776a4"
  "chrome/browser/ui/views/tabs/common/tab_view.cc" = "e8d8cb4facb9428bab15389a8fb137ada0982a21"
  "chrome/browser/ui/views/tabs/common/tab_view.h" = "04458f07af7f0aba0cd5446383df7074065330f2"
  "chrome/browser/ui/views/tabs/common/tab_view_browsertest.cc" = "0d800d7afb253c4a0f1dec5e07d33959d7882ced"
  "chrome/browser/ui/views/tabs/common/tab_view_vertical_layout.cc" = "6641560e2f254670b98975cfd02c81c3ed5ceea7"
  "chrome/browser/ui/views/tabs/vertical/vertical_tab_strip_bottom_container.cc" = "08d127e8a47a42a0d2d13f9a9e7cb21769e08d79"
  "chrome/browser/ui/views/tabs/vertical_tab_style_views.cc" = "cbec9de4fa9c629e50e8c13330f50ad2cca235e4"
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

$themePatchFiles = @(
  [regex]::Matches($themePatch, '(?m)^diff --git a/(.+?) b/') |
    ForEach-Object { $_.Groups[1].Value }
)
$expectedThemeBaseBlobs = [ordered]@{
  "chrome/browser/ui/color/chrome_color_mixers.cc" =
    "912072c8e1434a010c4dd9f3caebc0e3866197ae"
  "chrome/browser/ui/color/material_new_tab_page_color_mixer_unittest.cc" =
    "78b3b3716ed1fd99926a09ec9293ff6330066af1"
}
$unexpectedThemeFiles = @(
  $themePatchFiles |
    Where-Object { -not $expectedThemeBaseBlobs.Contains($_) }
)
$missingThemeFiles = @(
  $expectedThemeBaseBlobs.Keys |
    Where-Object { $_ -notin $themePatchFiles }
)
if ($unexpectedThemeFiles.Count -gt 0) {
  $failures.Add(
    "Theme patch touches unexpected files: $($unexpectedThemeFiles -join ', ')")
}
if ($missingThemeFiles.Count -gt 0) {
  $failures.Add(
    "Theme patch omits expected files: $($missingThemeFiles -join ', ')")
}
foreach ($path in $expectedThemeBaseBlobs.Keys) {
  $escapedPath = [regex]::Escape($path)
  $match = [regex]::Match(
    $themePatch,
    "(?m)^diff --git a/$escapedPath b/$escapedPath\r?\nindex ([0-9a-f]{40})\.\.([0-9a-f]{40}) 100644$")
  if (-not $match.Success) {
    $failures.Add("$path theme patch does not carry full blob hashes")
    continue
  }
  if ($match.Groups[1].Value -ne $expectedThemeBaseBlobs[$path]) {
    $failures.Add(
      "$path theme preimage mismatch: expected $($expectedThemeBaseBlobs[$path]), got $($match.Groups[1].Value)")
  }
}

Assert-PatchDoesNotMatch "upstream files only" '(?m)^(---|\+\+\+) /dev/null$'
Assert-ThemePatchDoesNotMatch "theme patch updates an upstream file" `
  '(?m)^(---|\+\+\+) /dev/null$'
Assert-PatchDoesNotMatch "no group-editor lifecycle overlap" `
  '(?m)^diff --git a/.+(tab_group_editor_bubble|saved_tab_group).+ b/'
Assert-PatchDoesNotMatch "no machine-specific source path" `
  'C:\\src\\kwiken-chromium'
Assert-PatchDoesNotMatch "no Git diagnostics" `
  '(?m)^warning: in the working copy'
Assert-ThemePatchDoesNotMatch "no theme-patch Git diagnostics" `
  '(?m)^warning: in the working copy'

# Geometry contracts and their real Views coverage.
Assert-PatchMatch "64 DIP expanded pinned minimum" `
  'kExpandedPinnedTabMinWidth = 64'
Assert-PatchMatch "32 DIP collapsed width remains Chromium-sized" `
  'kVerticalTabMinWidth:[\s\S]{0,80}return 32'
Assert-PatchMatch "44 DIP pinned tile height" `
  'kVerticalTabPinnedHeight:[\s\S]{0,80}\+\s+return 44'
Assert-PatchMatch "8 DIP grid gap" 'kPinnedTabGridGap = 8'
Assert-PatchMatch "12 DIP rail padding remains explicit" `
  '12 DIP rail inset[\s\S]{0,80}return 12'
Assert-PatchMatch "8 DIP corner radius remains explicit" `
  'kVerticalTabCornerRadius:[\s\S]{0,40}return 8'
Assert-PatchMatch "16 DIP favicon contract" `
  'kIconDesignWidth = 16[\s\S]{0,80}gfx::kFaviconSize'
Assert-PatchMatch "column math includes the trailing gap" `
  '\(available_width \+ kPinnedTabGridGap\)[\s\S]{0,120}\(minimum_child_width \+ kPinnedTabGridGap\)'
Assert-PatchMatch "preferred and minimum height use pinned geometry" `
  'kVerticalTabPinnedHeight[\s\S]{0,100}kPinnedTabGridGap'
Assert-PatchMatch "drag hit testing uses the grid gap" `
  'PinnedTabContainerView::GetLinkDropIndexForHorizontal[\s\S]{0,220}const int padding = is_vertical \? kPinnedTabGridGap : 0'
Assert-PatchDoesNotMatch "split pins do not inflate every grid cell" `
  '(?m)^\+.*contains_split'

Assert-PatchMatch "151 DIP two-column C++ coverage" `
  'PinnedTileGridGeometry[\s\S]+SizeBounds\(151, \{\}\)[\s\S]+child_layouts\[1\][\s\S]+child_layouts\[2\]'
Assert-PatchMatch "260 DIP three-column C++ coverage" `
  'PinnedTileGridGeometry[\s\S]+SizeBounds\(260, \{\}\)[\s\S]+child_layouts\[2\][\s\S]+child_layouts\[3\]'
Assert-PatchMatch "collapsed one-column C++ coverage" `
  'collapsed_layout[\s\S]+SizeBounds\(44, \{\}\)[\s\S]+EXPECT_EQ\(32,[\s\S]+EXPECT_EQ\(0, child_layout.bounds.x\(\)\)'
Assert-PatchMatch "height and gap C++ coverage" `
  'EXPECT_EQ\(44,[\s\S]+EXPECT_EQ\(8,[\s\S]+bounds.bottom\(\)'

# Expanded rail navigation hierarchy and calm folder rows.
Assert-PatchMatch "expanded pinned divider stays visible" `
  'persistent destinations visually distinct[\s\S]+should_show_separator[\s\S]+pinned_preferred_height != 0 && unpinned_preferred_height != 0'
Assert-PatchDoesNotMatch "expanded divider is not collapse-gated" `
  '(?m)^\+.*should_show_separator.*is_collapsed_|^\+\s*const bool should_show_separator\s*=\r?\n\+.*is_collapsed_'
Assert-PatchMatch "expanded New Tab label is enabled" `
  'new_tab_button_->SetShouldShowLabel\(true\)'
Assert-PatchMatch "folder header keeps neutral background" `
  'const ui::ColorId background_color =[\s\S]+kColorTabBackgroundInactiveFrameActive[\s\S]+kColorTabBackgroundInactiveFrameInactive'
Assert-PatchMatch "folder header carries selected hue in glyph" `
  'folder_icon_->SetImage[\s\S]+kFolderFlippableIcon[\s\S]+kFolderChromeRefreshOldIcon[\s\S]+group_color'
Assert-PatchMatch "expanded rail navigation C++ coverage" `
  'ExpandedRailKeepsZenNavigationCues[\s\S]+tabs_separator_for_testing\(\)->GetVisible\(\)[\s\S]+new_tab_button->GetText\(\)\.empty\(\)'
Assert-PatchDoesNotMatch "tests do not access protected label internals" `
  'new_tab_button->label\(\)'
Assert-PatchMatch "neutral folder C++ coverage" `
  'GroupHeaderUsesNeutralFolderTreatment[\s\S]+GetBackground\(\)->color\(\)[\s\S]+folder_icon_for_testing\(\)'

function Get-PinnedColumnCount {
  param(
    [Parameter(Mandatory = $true)]
    [int]$RailWidth,
    [Parameter(Mandatory = $true)]
    [bool]$Collapsed
  )

  $minimum = 64
  if ($Collapsed) {
    $minimum = 32
  }
  $available = [Math]::Max($minimum, $RailWidth - 12)
  if ($Collapsed) {
    return 1
  }
  return [int][Math]::Floor(($available + 8) / ($minimum + 8))
}

if ((Get-PinnedColumnCount -RailWidth 151 -Collapsed $false) -ne 2) {
  $failures.Add("151 DIP geometry does not resolve to two columns")
}
if ((Get-PinnedColumnCount -RailWidth 260 -Collapsed $false) -ne 3) {
  $failures.Add("260 DIP geometry does not resolve to three columns")
}
if ((Get-PinnedColumnCount -RailWidth 260 -Collapsed $true) -ne 1) {
  $failures.Add("collapsed geometry does not resolve to one column")
}

# Stable surfaces and split-pinned selection treatment.
Assert-PatchMatch "all pinned tabs paint a calm surface" `
  'Pinned tabs are persistent destinations[\s\S]{0,180}if \(delegate_->IsPinned\(\)\)[\s\S]{0,60}return true'
Assert-PatchMatch "2 DIP active outline" `
  'kVerticalTabPinnedBorderThickness:[\s\S]{0,80}\+\s+return 2'
Assert-PatchMatch "outline follows active tab state" `
  'ShouldPaintActivePinnedOutline\(\) const \{\r?\n\+\s+return orientation_ == TabStripOrientation::kVertical && pinned_ && active_;'
Assert-PatchMatch "inactive tile reserves matching inset" `
  'selection never shifts the favicon[\s\S]+CreateEmptyBorder\(gfx::Insets\(border_thickness\)\)'
Assert-PatchMatch "split-pinned tile chooses active child surface" `
  'background_tab[\s\S]+ShouldPaintActivePinnedOutline\(\)[\s\S]+GetBackgroundColor\(\)'
Assert-PatchMatch "split-pinned tile owns coherent outer outline" `
  'has_active_tab[\s\S]+kColorVerticalTabPinnedOutline[\s\S]+CreateEmptyBorder'
Assert-PatchMatch "active-only stable-border C++ coverage" `
  'PinnedTabsUseStableActiveOnlyOutline[\s\S]+EXPECT_FALSE\(first->ShouldPaintActivePinnedOutline\(\)\)[\s\S]+EXPECT_TRUE\(second->ShouldPaintActivePinnedOutline\(\)\)[\s\S]+GetInsets'

# Theme-selected colors own the palette; Kwiken preserves only Zen surface
# relationships so pinned destinations remain visually distinct.
Assert-ThemePatchMatch "active-frame pinned tile uses themed container" `
  'kColorTabBackgroundInactiveFrameActive\] = \{[\s\S]{0,80}ui::kColorSysHeaderContainer\}'
Assert-ThemePatchMatch "inactive-frame pinned tile uses themed container" `
  'kColorTabBackgroundInactiveFrameInactive\] = \{[\s\S]{0,80}ui::kColorSysHeaderContainerInactive\}'
Assert-ThemePatchMatch "pinned outline uses selected theme primary" `
  'kColorVerticalTabPinnedOutline\] = \{ui::kColorSysPrimary\}'
Assert-ThemePatchMatch "theme changes are delegated to Chromium" `
  'source every[\s\S]{0,100}color from Chromium''s selected theme'
Assert-ThemeMixerDoesNotMatch "no newly added literal palette" `
  '(?m)^\+.*(?:SkColorSet(?:RGB|ARGB)|SK_Color(?:WHITE|BLACK))'
Assert-ThemeMixerDoesNotMatch "no fixed frame or header override" `
  '(?m)^\+\s*mixer\[ui::kColor(?:Frame|SysHeader)'
Assert-ThemeMixerDoesNotMatch "toolbar and page colors remain theme-owned" `
  '(?m)^\+\s*mixer\[(?:kColorToolbar|kColorLocationBar|kColorOmnibox|kColorNewTabPage)'
Assert-ThemeMixerDoesNotMatch "group hues remain theme-owned" `
  '(?m)^\+\s*mixer\[kColorTabGroupTabStrip'
Assert-ThemePatchMatch "native theme-switch regression coverage" `
  'ZenRailFollowsSelectedTheme[\s\S]+GetZenRailColors[\s\S]+EXPECT_NE\(olive\.rail, blue\.rail\)[\s\S]+EXPECT_NE\(olive\.tile, blue\.tile\)[\s\S]+EXPECT_NE\(olive\.outline, blue\.outline\)'

Assert-TextMatch "high-contrast early bypass prerequisite" $brandPatch `
  'contrast_mode == ui::ColorProviderKey::ContrastMode::kHigh'
Assert-TextMatch "forced-colors early bypass prerequisite" $brandPatch `
  'forced_colors != ui::ColorProviderKey::ForcedColors::kNone'
Assert-TextMatch "custom-theme early bypass prerequisite" $brandPatch `
  'key.custom_theme \|\| key.app_controller'
Assert-TextMatch "Windows caption active color uses a declared Chromium ID" `
  $brandPatch 'kColorCaptionButtonForegroundActive'
Assert-TextMatch "Windows caption inactive color uses a declared Chromium ID" `
  $brandPatch 'kColorCaptionButtonForegroundInactive'
if ($brandPatch -match 'kColorVerticalTabsCaptionButtonForeground') {
  $failures.Add("branding patch references a nonexistent vertical-caption color ID")
}

# Explicit/manual and restored unload state feed the existing shared status bit.
Assert-PatchMatch "discarded state is promoted into shared status" `
  'should_show_discard_status =[\s\S]{0,100}ShouldShowDiscardStatus\(\) \|\| tab_data.is_tab_discarded'
Assert-PatchMatch "EXTERNAL unload notification is not reason-filtered" `
  'void TabUIHelper::WasDiscarded\(\)[\s\S]{0,500}tab_ui_change_callbacks_\.Notify\(\)'
Assert-PatchMatch "session-restored unloaded coverage" `
  'data_restored_unloaded[\s\S]+is_tab_discarded[\s\S]+should_show_discard_status[\s\S]+original_title[\s\S]+original_url'
Assert-PatchMatch "explicit-user unload visual coverage" `
  'ExplicitUserUnloadShowsPersistentTabStatus[\s\S]+UnloadTab\(\)[\s\S]+GetShowingDiscardIndicator\(\)'
Assert-PatchMatch "explicit-user unload accessibility coverage" `
  'ExplicitUserUnloadShowsPersistentTabStatus[\s\S]+IDS_TAB_AX_INACTIVE_TAB[\s\S]+GetCachedName\(\)[\s\S]+GetAccessibleTabLabel'
Assert-PatchMatch "unloaded identity and visual data stay intact" `
  'GetIndexOfTab\(unloaded_tab\)[\s\S]+IsPinned\(\)[\s\S]+GetLastCommittedURL\(\)[\s\S]+original_title[\s\S]+original_favicon'

if ($failures.Count -gt 0) {
  throw "Zen-rail patch contract failed:`n$($failures -join [Environment]::NewLine)"
}

Write-Output `
  "Zen-rail patch contract passed ($($actualFiles.Count) byte-pinned upstream files)."
