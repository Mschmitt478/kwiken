$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$workflowPath = Join-Path $repoRoot ".github\workflows\release.yml"
$source = Get-Content -LiteralPath $workflowPath -Raw
$lines = @(Get-Content -LiteralPath $workflowPath)

function Assert-True {
  param(
    [Parameter(Mandatory = $true)]
    [bool]$Condition,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )
  if (-not $Condition) { throw $Message }
}

function Assert-Contains {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Needle,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )
  Assert-True -Condition ($source.IndexOf(
      $Needle,
      [StringComparison]::Ordinal
    ) -ge 0) -Message $Message
}

function Assert-NotMatch {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Pattern,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )
  Assert-True -Condition (-not [regex]::IsMatch(
      $source,
      $Pattern,
      [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
        [Text.RegularExpressions.RegexOptions]::Multiline
    )) -Message $Message
}

Assert-True -Condition (Test-Path -LiteralPath $workflowPath -PathType Leaf) `
  -Message "release.yml is missing."
Assert-True -Condition ($source.IndexOf([char]9) -lt 0) `
  -Message "release.yml must not contain YAML tab indentation."
Assert-NotMatch -Pattern '[ \t]+$' -Message "release.yml has trailing whitespace."
Assert-True -Condition ([regex]::IsMatch(
    $source,
    '(?m)^on:\r?\n  workflow_dispatch:\s*$'
  )) -Message "Release candidate workflow must be workflow_dispatch-only."
Assert-NotMatch `
  -Pattern '^\s{2}(push|pull_request|pull_request_target|schedule|workflow_call|workflow_run|repository_dispatch):' `
  -Message "An automatic or callable release trigger remains."
Assert-Contains -Needle "group: kwiken-unsigned-candidate" `
  -Message "Persistent native roots are not protected by one global workflow lock."
Assert-NotMatch -Pattern 'group:\s*kwiken-unsigned-candidate-\$\{\{' `
  -Message "Per-ref concurrency can race the shared Chromium checkout."
$defaultBranchCondition = 'if: ${{ github.ref == format(''refs/heads/{0}'', github.event.repository.default_branch) }}'
Assert-True -Condition (([regex]::Matches(
      $source,
      [regex]::Escape($defaultBranchCondition)
    )).Count -eq 2) `
  -Message "Both jobs must reject dispatches outside the repository default branch."

Assert-Contains -Needle "permissions: {}" `
  -Message "The workflow must deny all token permissions by default."
Assert-True -Condition (([regex]::Matches(
      $source,
      '(?m)^\s{6}contents:\s+read\s*$'
    )).Count -eq 2) `
  -Message "Both jobs must request only contents:read."
Assert-NotMatch -Pattern 'contents:\s*write|actions:\s*write|id-token:\s*write|attestations:\s*write|packages:\s*write' `
  -Message "Release workflow has a publishing/signing permission."
Assert-NotMatch -Pattern '\bsecrets\.|GITHUB_TOKEN|GH_TOKEN' `
  -Message "Unsigned candidate workflow must not receive release credentials."

$controlledRunner = "runs-on: [self-hosted, Windows, X64, kwiken-chromium]"
Assert-True -Condition (($source.Split([string[]]@("`r`n", "`n"),
      [StringSplitOptions]::None) | Where-Object {
        $_.Trim() -ceq $controlledRunner
      }).Count -eq 2) `
  -Message "Both jobs must target the explicit controlled Kwiken runner labels."
Assert-NotMatch -Pattern 'windows-latest|windows-20[0-9]{2}|ubuntu-|macos-' `
  -Message "A hosted runner bypass remains."

$approvedActions = @{
  "actions/checkout" = "3d3c42e5aac5ba805825da76410c181273ba90b1"
  "actions/upload-artifact" = "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
  "actions/download-artifact" = "3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c"
}
$uses = [regex]::Matches(
  $source,
  '(?m)^\s*-?\s*uses:\s*([^\s@]+)@([0-9a-f]{40})(?:\s+#.*)?$'
)
Assert-True -Condition ($uses.Count -eq 5) `
  -Message "Workflow must contain exactly two checkouts, two uploads, and one download."
foreach ($use in $uses) {
  $repository = $use.Groups[1].Value
  $revision = $use.Groups[2].Value
  Assert-True -Condition ($approvedActions.ContainsKey($repository)) `
    -Message "Unapproved third-party action is used: $repository"
  Assert-True -Condition ($approvedActions[$repository] -ceq $revision) `
    -Message "$repository is not pinned to its reviewed immutable revision."
}
foreach ($repository in $approvedActions.Keys) {
  Assert-True -Condition (@($uses | Where-Object {
        $_.Groups[1].Value -ceq $repository
      }).Count -ge 1) -Message "Required pinned action is missing: $repository"
}
Assert-NotMatch -Pattern 'uses:\s*[^\s]+@(v[0-9]+|main|master|HEAD)\b' `
  -Message "A mutable action reference remains."

Assert-True -Condition (([regex]::Matches(
      $source,
      '(?m)^\s+ref:\s*\$\{\{ github\.sha \}\}\s*$'
    )).Count -eq 2) `
  -Message "Both jobs must checkout the exact workflow commit."
Assert-True -Condition (([regex]::Matches(
      $source,
      '(?m)^\s+persist-credentials:\s*false\s*$'
    )).Count -eq 2) `
  -Message "Checkout credentials must never persist."
Assert-Contains -Needle 'Checkout revision does not equal the workflow commit.' `
  -Message "Producer does not independently verify its exact checkout."
Assert-Contains -Needle 'Packaging checkout does not equal the producer commit.' `
  -Message "Packager does not independently verify its exact checkout."

foreach ($requiredStep in @(
    "Bootstrap preflight",
    "Bootstrap pinned Chromium checkout",
    "Native build preflight",
    "Export native runtime",
    "Stage immutable native handoff",
    "Upload authenticated native handoff",
    "Download exact native handoff artifact",
    "Verify handoff and package unsigned candidate",
    "Upload unsigned candidate and provenance"
  )) {
  Assert-Contains -Needle "name: $requiredStep" `
    -Message "Required staged release step is missing: $requiredStep"
}
Assert-Contains -Needle 'artifact-id: ${{ steps.upload-handoff.outputs.artifact-id }}' `
  -Message "Producer does not expose immutable artifact ID."
Assert-Contains -Needle 'artifact-digest: ${{ steps.upload-handoff.outputs.artifact-digest }}' `
  -Message "Producer does not expose artifact digest."
Assert-Contains -Needle 'ready-sha256: ${{ steps.stage-handoff.outputs.ready-sha256 }}' `
  -Message "Producer does not expose external READY trust."
Assert-Contains -Needle 'artifact-ids: ${{ needs.native-runtime.outputs.artifact-id }}' `
  -Message "Packager does not download the producer's exact artifact ID."
Assert-Contains -Needle "digest-mismatch: error" `
  -Message "Artifact download does not explicitly fail on service digest mismatch."
Assert-Contains -Needle 'EXPECTED_ARTIFACT_DIGEST: ${{ needs.native-runtime.outputs.artifact-digest }}' `
  -Message "Packager drops the artifact service digest."
Assert-Contains -Needle 'EXPECTED_READY_SHA256: ${{ needs.native-runtime.outputs.ready-sha256 }}' `
  -Message "Packager drops external READY trust."
Assert-Contains -Needle 'Downloaded READY does not match the producer''s external hash.' `
  -Message "Downloaded runtime is not re-bound to producer READY trust."
Assert-Contains -Needle 'Native export directory has an unexpected file set.' `
  -Message "Producer does not close the native handoff file set."
Assert-Contains -Needle 'Downloaded runtime handoff has an unexpected file set.' `
  -Message "Packager does not close the downloaded runtime file set."

foreach ($variable in @(
    "KWIKEN_CHROMIUM_ROOT",
    "KWIKEN_DEPOT_TOOLS_ROOT",
    "KWIKEN_VISUAL_STUDIO_ROOT",
    "KWIKEN_WEB_STORE_ARCHIVE",
    "KWIKEN_NSIS_RUNTIME_ROOT",
    "KWIKEN_NSIS_EXE_SHA256",
    "KWIKEN_NSIS_RUNTIME_TREE_SHA256"
  )) {
  $variableBinding = $variable + ': ${{ vars.' + $variable + ' }}'
  Assert-Contains -Needle $variableBinding `
    -Message "Controlled-runner variable is not explicit: $variable"
}
Assert-Contains `
  -Needle "KWIKEN_WEB_STORE_SHA256: 627cb80dd67d16e4d2a9f105c1a1c5adf61dca63202bd577a4e4af84bd07868c" `
  -Message "Web Store source archive is not pinned."
Assert-Contains -Needle 'Pre-provisioned NSIS does not match independent pinned hashes.' `
  -Message "NSIS executable/tree are not independently checked."
Assert-Contains -Needle 'Packaging inputs do not match independent hashes before native production.' `
  -Message "Missing packaging tools would be discovered only after the native build."
Assert-Contains -Needle 'Get-ToolTreeSha256 -Root $pythonRoot' `
  -Message "Transferred pinned Python runtime is not tree-hash checked."
Assert-Contains -Needle 'Tool runtime contains more than 50000 files.' `
  -Message "Workflow tool-tree verification lacks a file-count bound."
Assert-Contains -Needle 'Tool runtime exceeds the 2 GiB input limit.' `
  -Message "Workflow tool-tree verification lacks a byte bound."
Assert-NotMatch -Pattern 'choco(?:latey)?\s+install|winget\s+install|Invoke-WebRequest|curl(?:\.exe)?\s|setup-python@' `
  -Message "Workflow still downloads mutable packaging tools at runtime."

$bridgeArguments = @(
  "-RuntimeReadyPath",
  "-RuntimeArchive",
  "-RuntimeManifest",
  "-ExpectedReadySha256",
  "-WebStoreArchive",
  "-PythonPath",
  "-PythonRuntimeRoot",
  "-ExpectedPythonSha256",
  "-ExpectedPythonRuntimeTreeSha256",
  "-MakeNsisPath",
  "-MakeNsisRuntimeRoot",
  "-ExpectedMakeNsisSha256",
  "-ExpectedMakeNsisRuntimeTreeSha256"
)
foreach ($argument in $bridgeArguments) {
  Assert-Contains -Needle $argument `
    -Message "Workflow omits mandatory build-distribution input $argument."
}

Assert-Contains -Needle 'releaseReady = $false' `
  -Message "Unsigned provenance does not explicitly reject release readiness."
Assert-Contains -Needle 'signed = $false' `
  -Message "Unsigned provenance does not disclose signing state."
Assert-Contains -Needle 'UNSIGNED.NOT-FOR-PUBLICATION.json' `
  -Message "Unsigned artifact lacks a fail-closed provenance marker."
Assert-Contains -Needle 'environment-approved Authenticode signing, signature verification, attestation, and immutable publication' `
  -Message "Required downstream release gate is not explicit."
foreach ($forbidden in @(
    "gh release",
    "create release",
    "upload release",
    "--clobber",
    "git tag",
    "git push",
    "contents: write",
    "release create",
    "release upload"
  )) {
  Assert-True -Condition ($source.IndexOf(
      $forbidden,
      [StringComparison]::OrdinalIgnoreCase
    ) -lt 0) -Message "Publishing operation remains in unsigned workflow: $forbidden"
}

# Every `run: |` block in this workflow declares pwsh. Extract and parse those
# scripts with the current engine, so this test exercises PS 7 and PS 5.1
# grammar when invoked under each edition without needing a YAML dependency.
$runBlocks = 0
for ($index = 0; $index -lt $lines.Count; $index++) {
  if ($lines[$index] -notmatch '^(\s*)run:\s*\|\s*$') { continue }
  $runBlocks++
  $runIndent = $Matches[1].Length
  $body = [Collections.Generic.List[string]]::new()
  $minimumBodyIndent = $null
  for ($cursor = $index + 1; $cursor -lt $lines.Count; $cursor++) {
    $line = $lines[$cursor]
    if ([string]::IsNullOrWhiteSpace($line)) {
      $body.Add("")
      continue
    }
    $indent = $line.Length - $line.TrimStart().Length
    if ($indent -le $runIndent) { break }
    if ($null -eq $minimumBodyIndent -or $indent -lt $minimumBodyIndent) {
      $minimumBodyIndent = $indent
    }
    $body.Add($line)
  }
  Assert-True -Condition ($null -ne $minimumBodyIndent) `
    -Message "Empty workflow run block at line $($index + 1)."
  $scriptLines = foreach ($line in $body) {
    if ([string]::IsNullOrEmpty($line)) { "" } else {
      $line.Substring([int]$minimumBodyIndent)
    }
  }
  $tokens = $null
  $parseErrors = $null
  [void][Management.Automation.Language.Parser]::ParseInput(
    ($scriptLines -join "`n"),
    [ref]$tokens,
    [ref]$parseErrors
  )
  Assert-True -Condition ($parseErrors.Count -eq 0) `
    -Message "PowerShell parse error in workflow run block at line $($index + 1): $($parseErrors -join '; ')"
}
Assert-True -Condition ($runBlocks -eq 7) `
  -Message "Unexpected workflow run-block count; update the contract intentionally."

$yamlCommand = Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue
if ($yamlCommand) {
  [void]($source | ConvertFrom-Yaml -ErrorAction Stop)
  Write-Output "release.yml parsed with ConvertFrom-Yaml."
} else {
  Write-Output "No YAML parser is installed; structural and embedded-script checks were used."
}

Write-Output "release.yml fail-closed workflow contract tests passed."
