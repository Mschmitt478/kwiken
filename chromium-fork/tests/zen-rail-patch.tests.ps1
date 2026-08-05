$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$forkRoot = Split-Path -Parent $PSScriptRoot
$patchPath = Join-Path $forkRoot "patches\0006-kwiken-zen-rail.patch"
$brandPatchPath = Join-Path $forkRoot "patches\0001-kwiken-browser.patch"

foreach ($requiredPath in @($patchPath, $brandPatchPath)) {
  if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    throw "Required patch is missing: $requiredPath"
  }
}

$patch = [IO.File]::ReadAllText($patchPath)
$brandPatch = [IO.File]::ReadAllText($brandPatchPath)
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

$expectedBaseBlobs = [ordered]@{
  "chrome/browser/ui/color/chrome_color_mixers.cc" = "e33f8a4753b05ac5baa268970d454291497213f0"
  "chrome/browser/ui/layout_constants.cc" = "b2c1709b4c2ac60dfc9b436ab9c75e4212e92dc2"
  "chrome/browser/ui/tab_ui_helper.cc" = "ef6e48fcb4d483798bfcc2723b483fea14ead78a"
  "chrome/browser/ui/tabs/tab_data.cc" = "84682b0f8437b952f7ed8607ab31a2f7f958938c"
  "chrome/browser/ui/tabs/tab_data_browsertest.cc" = "f05ddcb8be2db09098ad01904d3443f68ae83d09"
  "chrome/browser/ui/views/tabs/vertical/vertical_pinned_tab_container_view.cc" = "58c8ef10b31d8b8e1baae2bb2f1f72cc6a9ffc32"
  "chrome/browser/ui/views/tabs/vertical/vertical_split_tab_view.cc" = "1970367feaccf631955d558a8ecc1acda4724ff1"
  "chrome/browser/ui/views/tabs/vertical/vertical_split_tab_view.h" = "50f7bbb8e79df391e060e8006459bd82327b9947"
  "chrome/browser/ui/views/tabs/vertical/vertical_tab_group_header_view.cc" = "afcfdc886261e044f0d0033086d1e2c87c47685d"
  "chrome/browser/ui/views/tabs/vertical/vertical_tab_group_header_view.h" = "060713491fad09c839d6500545af22bac3ec192e"
  "chrome/browser/ui/views/tabs/vertical/vertical_tab_strip_bottom_container.cc" = "32c64e73c5e2ef5ca5561c349381d35754b72d87"
  "chrome/browser/ui/views/tabs/vertical/vertical_tab_strip_link_drag_browsertest.cc" = "63a17434753087cc0f0f31ecf3b17fb0264a9b04"
  "chrome/browser/ui/views/tabs/vertical/vertical_tab_strip_view.cc" = "d09396a6077ef46c9f334721af66111800b445c4"
  "chrome/browser/ui/views/tabs/vertical/vertical_tab_view.cc" = "eb9e13ce3d2dca019b4a9758bcd7ef4dc7846dc8"
  "chrome/browser/ui/views/tabs/vertical/vertical_tab_view.h" = "30bddac23a66df179d081a021600b76d82d378a1"
  "chrome/browser/ui/views/tabs/vertical/vertical_tab_view_browsertest.cc" = "b007fd08048281088fa7a2af0ae4da4021e1ea51"
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
Assert-PatchDoesNotMatch "no group-editor lifecycle overlap" `
  '(?m)^diff --git a/.+(tab_group_editor_bubble|saved_tab_group).+ b/'
Assert-PatchDoesNotMatch "no machine-specific source path" `
  'C:\\src\\kwiken-chromium'
Assert-PatchDoesNotMatch "no Git diagnostics" `
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
  'GetLinkDropIndexForExpanded[\s\S]+kPinnedTabGridGap / 2[\s\S]+kPinnedTabGridGap'
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
  'Pinned tabs are persistent destinations[\s\S]+if \(pinned_\)[\s\S]+return true'
Assert-PatchMatch "2 DIP active outline" `
  'kVerticalTabPinnedBorderThickness:[\s\S]{0,80}\+\s+return 2'
Assert-PatchMatch "outline follows active tab state" `
  'ShouldPaintActivePinnedOutline\(\) const \{ return pinned_ && active_; \}'
Assert-PatchMatch "inactive tile reserves matching inset" `
  'selection never shifts the favicon[\s\S]+CreateEmptyBorder\(gfx::Insets\(border_thickness\)\)'
Assert-PatchMatch "split-pinned tile chooses active child surface" `
  'background_tab[\s\S]+ShouldPaintActivePinnedOutline\(\)[\s\S]+GetBackgroundColor\(\)'
Assert-PatchMatch "split-pinned tile owns coherent outer outline" `
  'has_active_tab[\s\S]+kColorVerticalTabPinnedOutline[\s\S]+CreateEmptyBorder'
Assert-PatchMatch "active-only stable-border C++ coverage" `
  'PinnedTabsUseStableActiveOnlyOutline[\s\S]+EXPECT_FALSE\(first->ShouldPaintActivePinnedOutline\(\)\)[\s\S]+EXPECT_TRUE\(second->ShouldPaintActivePinnedOutline\(\)\)[\s\S]+GetInsets'

# Palette, bypass, toolbar readability, and user-selected group hue semantics.
foreach ($colorContract in @(
    @("rail", 'SkColorSetRGB\(0x7D, 0x68, 0x82\)'),
    @("raised tile", 'SkColorSetRGB\(0x75, 0x61, 0x7A\)'),
    @("hover", 'SkColorSetRGB\(0x8A, 0x74, 0x8F\)'),
    @("active tile", 'SkColorSetRGB\(0xDC, 0xD6, 0xDD\)'),
    @("active foreground", 'SkColorSetRGB\(0x2D, 0x26, 0x30\)'),
    @("inactive foreground", 'SkColorSetRGB\(0xF1, 0xEB, 0xF2\)'),
    @("muted", 'SkColorSetRGB\(0xD0, 0xC4, 0xD2\)'),
    @("blush accent", 'SkColorSetRGB\(0xE5, 0xC6, 0xD1\)')
  )) {
  Assert-PatchMatch "$($colorContract[0]) palette" $colorContract[1]
}
Assert-PatchMatch "deeper purple private rail" `
  'private_palette \? SkColorSetRGB\(0x2A, 0x20, 0x2F\)'
Assert-PatchMatch "private content palette stays readable" `
  'paper = private_palette \? SkColorSetRGB\(0x1B, 0x15, 0x1E\)[\s\S]+paper_text[\s\S]+kColorToolbar\] = \{paper\}'
Assert-PatchMatch "active foreground is dark on the pale tile" `
  'kColorTabForegroundActiveFrameActive\] = \{active_foreground\}'
Assert-PatchMatch "inactive foreground remains light" `
  'kColorTabForegroundInactiveFrameActive\] = \{text\}'
Assert-PatchMatch "blush is the pinned outline" `
  'kColorVerticalTabPinnedOutline\] = \{accent\}'

foreach ($groupColor in @(
    "Grey", "Blue", "Red", "Yellow", "Green", "Pink", "Purple", "Cyan", "Orange"
  )) {
  Assert-PatchMatch "calm $groupColor group semantics" `
    "kColorTabGroupTabStripFrameActive$groupColor"
  Assert-PatchMatch "inactive $groupColor group semantics" `
    "kColorTabGroupTabStripFrameInactive$groupColor"
}

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
