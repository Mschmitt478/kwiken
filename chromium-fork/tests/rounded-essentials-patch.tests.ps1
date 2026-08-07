$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$forkRoot = Split-Path -Parent $PSScriptRoot
$patchPath = Join-Path $forkRoot `
  "patches\0008-kwiken-rounded-essentials.patch"
if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
  throw "Required patch is missing: $patchPath"
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
  "chrome/app/generated_resources.grd" =
    "960819159d07c65bab2845b130a6bbcb8baebd86"
  "chrome/browser/ui/tabs/tab_menu_model.cc" =
    "aac534e5d86f2d81b9e5252d6dd9afa039110f5a"
  "chrome/browser/ui/tabs/tab_menu_model_browsertest.cc" =
    "d8d38a39b2b59ad6a61aed33b770fe281ef13184"
  "chrome/browser/ui/views/tabs/vertical/BUILD.gn" =
    "670ca28e949e9c77596dd5212503a1cf65465901"
  "chrome/browser/ui/views/tabs/vertical/vertical_tab_view.cc" =
    "432164fcad0acd75b598c00eecb99b28815c577e"
  "chrome/browser/ui/views/tabs/vertical/vertical_tab_view_browsertest.cc" =
    "12f991733acba7daa8716fec2812d86f548ab8e2"
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
Assert-PatchDoesNotMatch "no machine-specific source path" `
  'C:\\src\\kwiken-chromium'
Assert-PatchDoesNotMatch "no Git diagnostics" `
  '(?m)^warning: in the working copy'

# The fill, not only the active outline, owns the rounded geometry. Theme
# images use the same path so switching themes cannot bring the square bug back.
Assert-PatchMatch "content-bounds rounded fill path" `
  'SkPath::RRect\(SkRRect::MakeRectXY\([\s\S]{0,160}GetContentsBounds\(\)[\s\S]{0,120}corner_radius'
Assert-PatchMatch "solid fill uses rounded path" `
  '(?m)^\+\s+canvas->DrawPath\(fill_path, flags\);$'
Assert-PatchMatch "theme image is clipped to rounded path" `
  'ScopedCanvas scoped_canvas\(canvas\)[\s\S]{0,100}ClipPath\(fill_path'
Assert-PatchDoesNotMatch "square fill is not reintroduced" `
  '(?m)^\+\s+canvas->DrawRect\(GetContentsBounds\(\), flags\);$'

# Normal windows backed by the durable pinned-tab service expose the Zen
# vocabulary. Other windows and profiles retain Chromium wording instead of
# promising persistence they do not have.
Assert-PatchMatch "Add to Essentials resource" `
  'IDS_TAB_CXMENU_ADD_TO_ESSENTIALS[\s\S]{0,220}Add to Essentials'
Assert-PatchMatch "Remove from Essentials resource" `
  'IDS_TAB_CXMENU_REMOVE_FROM_ESSENTIALS[\s\S]{0,240}Remove from Essentials'
Assert-PatchMatch "durable normal-window Essential vocabulary" `
  'delegate\(\)->IsNormalWindow\(\)[\s\S]{0,180}PinnedTabServiceFactory::GetForProfile\(tab_strip_->profile\(\)\)[\s\S]{0,260}IDS_TAB_CXMENU_ADD_TO_ESSENTIALS[\s\S]{0,100}IDS_TAB_CXMENU_REMOVE_FROM_ESSENTIALS'
Assert-PatchMatch "private-session Pin fallback" `
  'IDS_TAB_CXMENU_PIN_TAB : IDS_TAB_CXMENU_UNPIN_TAB'
Assert-PatchMatch "existing pin command remains implementation seam" `
  'AddItemWithStringId\(TabStripModel::CommandTogglePinned'

# Native coverage proves both the exact menu transition/lifecycle exposure and
# the raster result that the screenshot revealed.
Assert-PatchMatch "Essential menu browser coverage" `
  'RegularProfileUsesEssentialsForPersistentPins[\s\S]+IDS_TAB_CXMENU_ADD_TO_ESSENTIALS[\s\S]+IsPinned\(\)[\s\S]+IDS_TAB_CXMENU_REMOVE_FROM_ESSENTIALS[\s\S]+CommandUnloadTab'
Assert-PatchMatch "popup Pin fallback browser coverage" `
  'RegularProfilePopupRetainsPinTerminology[\s\S]{0,1400}IDS_TAB_CXMENU_PIN_TAB'
Assert-PatchMatch "off-the-record Pin fallback browser coverage" `
  'OffTheRecordNormalWindowRetainsPinTerminology[\s\S]{0,2400}IDS_TAB_CXMENU_PIN_TAB[\s\S]{0,1800}IDS_TAB_CXMENU_UNPIN_TAB'
Assert-PatchMatch "inactive tile raster coverage" `
  'PaintViewToBitmap\(first\)[\s\S]{0,400}contents\.x\(\), contents\.y\(\)[\s\S]{0,240}contents\.x\(\) \+ 2[\s\S]{0,180}fill_sample'
Assert-PatchMatch "Views drawing test dependency" `
  '(?m)^\+\s+"//ui/views:test_support",$'
Assert-PatchMatch "Skia test dependency" `
  '(?m)^\+\s+"//skia",$'

if ($failures.Count -gt 0) {
  throw "Rounded-Essentials patch contract failed:`n$($failures -join [Environment]::NewLine)"
}

Write-Output `
  "Rounded-Essentials patch contract passed ($($actualFiles.Count) byte-pinned upstream files)."
