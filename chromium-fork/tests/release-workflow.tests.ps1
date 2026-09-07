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

# Parse the deliberately small YAML subset used by release.yml. This is a
# closed grammar: unsupported YAML features are rejected instead of being
# treated as strings, so structural assertions never fall back to text-only
# checks when no external parser is installed.
function Remove-KwikenYamlInlineComment {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Value
  )

  $singleQuoted = $false
  $doubleQuoted = $false
  $escaped = $false
  for ($index = 0; $index -lt $Value.Length; $index++) {
    $character = $Value[$index]
    if ($doubleQuoted) {
      if ($escaped) {
        $escaped = $false
      } elseif ($character -eq '\') {
        $escaped = $true
      } elseif ($character -eq '"') {
        $doubleQuoted = $false
      }
      continue
    }
    if ($singleQuoted) {
      if ($character -eq "'") {
        if ($index + 1 -lt $Value.Length -and $Value[$index + 1] -eq "'") {
          $index++
        } else {
          $singleQuoted = $false
        }
      }
      continue
    }
    if ($character -eq '"') {
      $doubleQuoted = $true
    } elseif ($character -eq "'") {
      $singleQuoted = $true
    } elseif ($character -eq '#' -and
        ($index -eq 0 -or [char]::IsWhiteSpace($Value[$index - 1]))) {
      return $Value.Substring(0, $index).TrimEnd()
    }
  }
  if ($singleQuoted -or $doubleQuoted -or $escaped) {
    throw "Unterminated quoted YAML scalar: $Value"
  }
  return $Value.TrimEnd()
}

function ConvertFrom-KwikenYamlScalar {
  param(
    [Parameter(Mandatory = $true)][string]$Value,
    [Parameter(Mandatory = $true)][int]$LineNumber
  )

  $text = (Remove-KwikenYamlInlineComment -Value $Value).Trim()
  if ($text -ceq '{}') { return [ordered]@{} }
  if ($text -ceq '[]') { return @() }
  if ($text.StartsWith('[') -or $text.EndsWith(']')) {
    if (-not ($text.StartsWith('[') -and $text.EndsWith(']'))) {
      throw "Malformed flow sequence at YAML line $LineNumber."
    }
    $inner = $text.Substring(1, $text.Length - 2)
    if ([string]::IsNullOrWhiteSpace($inner)) { return @() }
    $items = [Collections.Generic.List[object]]::new()
    $current = [Text.StringBuilder]::new()
    $singleQuoted = $false
    $doubleQuoted = $false
    $escaped = $false
    foreach ($character in $inner.ToCharArray()) {
      if ($doubleQuoted) {
        [void]$current.Append($character)
        if ($escaped) { $escaped = $false }
        elseif ($character -eq '\') { $escaped = $true }
        elseif ($character -eq '"') { $doubleQuoted = $false }
      } elseif ($singleQuoted) {
        [void]$current.Append($character)
        if ($character -eq "'") { $singleQuoted = $false }
      } elseif ($character -eq '"') {
        $doubleQuoted = $true
        [void]$current.Append($character)
      } elseif ($character -eq "'") {
        $singleQuoted = $true
        [void]$current.Append($character)
      } elseif ($character -eq ',') {
        if ([string]::IsNullOrWhiteSpace($current.ToString())) {
          throw "Empty flow-sequence item at YAML line $LineNumber."
        }
        $items.Add((ConvertFrom-KwikenYamlScalar `
            -Value $current.ToString() -LineNumber $LineNumber))
        [void]$current.Clear()
      } elseif ($character -eq '[' -or $character -eq ']' -or
          $character -eq '{' -or $character -eq '}') {
        throw "Nested YAML flow collections are outside the reviewed subset at line $LineNumber."
      } else {
        [void]$current.Append($character)
      }
    }
    if ($singleQuoted -or $doubleQuoted -or
        [string]::IsNullOrWhiteSpace($current.ToString())) {
      throw "Malformed flow sequence at YAML line $LineNumber."
    }
    $items.Add((ConvertFrom-KwikenYamlScalar `
        -Value $current.ToString() -LineNumber $LineNumber))
    return $items.ToArray()
  }
  if ($text.StartsWith('"') -or $text.EndsWith('"')) {
    if (-not ($text.StartsWith('"') -and $text.EndsWith('"'))) {
      throw "Malformed double-quoted scalar at YAML line $LineNumber."
    }
    try { return $text | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Invalid double-quoted scalar at YAML line $LineNumber`: $($_.Exception.Message)" }
  }
  if ($text.StartsWith("'") -or $text.EndsWith("'")) {
    if (-not ($text.StartsWith("'") -and $text.EndsWith("'"))) {
      throw "Malformed single-quoted scalar at YAML line $LineNumber."
    }
    $singleQuotedValue = $text.Substring(1, $text.Length - 2)
    for ($index = 0; $index -lt $singleQuotedValue.Length; $index++) {
      if ($singleQuotedValue[$index] -ne "'") { continue }
      if ($index + 1 -ge $singleQuotedValue.Length -or
          $singleQuotedValue[$index + 1] -ne "'") {
        throw "Malformed single-quoted scalar at YAML line $LineNumber."
      }
      $index++
    }
    return $singleQuotedValue.Replace("''", "'")
  }
  if ($text -cmatch '^(true|false)$') { return [bool]::Parse($text) }
  if ($text -cmatch '^(null|~)$') { return $null }
  if ($text -cmatch '^-?(?:0|[1-9][0-9]*)$') { return [long]$text }
  if ([string]::IsNullOrWhiteSpace($text) -or
      $text -match '^(?:---|\.\.\.)(?:\s|$)' -or
      $text -match '^[-?:](?:\s|$)' -or
      $text -match '^[,\[\]{}#&*!|>%@`]' -or
      $text -match '(?:^|\s)[&*!]' -or
      $text -match ':$|:\s') {
    throw "Invalid plain YAML scalar at line $LineNumber."
  }
  foreach ($character in $text.ToCharArray()) {
    if ([char]::IsControl($character)) {
      throw "Control character in plain YAML scalar at line $LineNumber."
    }
  }
  return $text
}

function Get-KwikenYamlLine {
  param([Parameter(Mandatory = $true)][int]$Index)

  $raw = $script:KwikenYamlLines[$Index]
  $trimmed = $raw.TrimStart(' ')
  return [pscustomobject]@{
    Index = $Index
    LineNumber = $Index + 1
    Indent = $raw.Length - $trimmed.Length
    Content = $trimmed
  }
}

function MoveTo-KwikenYamlContent {
  while ($script:KwikenYamlIndex -lt $script:KwikenYamlLines.Count) {
    $line = Get-KwikenYamlLine -Index $script:KwikenYamlIndex
    if (-not [string]::IsNullOrWhiteSpace($line.Content) -and
        -not $line.Content.StartsWith('#')) {
      return $line
    }
    $script:KwikenYamlIndex++
  }
  return $null
}

function Read-KwikenYamlBlockScalar {
  param(
    [Parameter(Mandatory = $true)][int]$ParentIndent,
    [Parameter(Mandatory = $true)][string]$Indicator
  )

  $start = $script:KwikenYamlIndex
  $cursor = $start
  $requiredIndent = $null
  while ($cursor -lt $script:KwikenYamlLines.Count) {
    $raw = $script:KwikenYamlLines[$cursor]
    if ([string]::IsNullOrWhiteSpace($raw)) { $cursor++; continue }
    $line = Get-KwikenYamlLine -Index $cursor
    if ($line.Indent -le $ParentIndent) { break }
    if ($null -eq $requiredIndent) {
      $requiredIndent = $line.Indent
    } elseif ($line.Indent -lt $requiredIndent) {
      throw "Malformed YAML block indentation at line $($line.LineNumber)."
    }
    $cursor++
  }
  if ($null -eq $requiredIndent) {
    throw "Empty YAML block scalar after line $start."
  }
  $content = for ($index = $start; $index -lt $cursor; $index++) {
    $raw = $script:KwikenYamlLines[$index]
    if ([string]::IsNullOrWhiteSpace($raw)) { '' }
    elseif ($raw.Length -lt $requiredIndent) {
      throw "Malformed YAML block indentation at line $($index + 1)."
    } else {
      $raw.Substring($requiredIndent)
    }
  }
  $script:KwikenYamlIndex = $cursor
  $text = $content -join "`n"
  if ($Indicator -ceq '|-') { return $text.TrimEnd("`n") }
  return $text + "`n"
}

function Read-KwikenYamlValue {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RawValue,
    [Parameter(Mandatory = $true)][int]$ParentIndent,
    [Parameter(Mandatory = $true)][int]$LineNumber
  )

  $value = (Remove-KwikenYamlInlineComment -Value $RawValue).Trim()
  if ($value -cmatch '^\|-?$') {
    return Read-KwikenYamlBlockScalar -ParentIndent $ParentIndent `
      -Indicator $value
  }
  if (-not [string]::IsNullOrEmpty($value)) {
    return ConvertFrom-KwikenYamlScalar -Value $value -LineNumber $LineNumber
  }
  $next = MoveTo-KwikenYamlContent
  if ($null -eq $next -or $next.Indent -le $ParentIndent) { return $null }
  if ($next.Indent -ne $ParentIndent + 2) {
    throw "Unexpected YAML indentation at line $($next.LineNumber)."
  }
  return Read-KwikenYamlNode -Indent $next.Indent
}

function Add-KwikenYamlMappingEntry {
  param(
    [Parameter(Mandatory = $true)][Collections.Specialized.OrderedDictionary]$Mapping,
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][int]$Indent,
    [Parameter(Mandatory = $true)][int]$LineNumber
  )

  $match = [regex]::Match(
    $Content,
    '^(?<key>[A-Za-z0-9_.-]+):(?: (?<value>.*))?$'
  )
  if (-not $match.Success) {
    throw "Invalid YAML mapping entry at line $LineNumber."
  }
  $key = $match.Groups['key'].Value
  if ($Mapping.Contains($key)) {
    throw "Duplicate YAML key '$key' at line $LineNumber."
  }
  $Mapping[$key] = Read-KwikenYamlValue `
    -RawValue $match.Groups['value'].Value -ParentIndent $Indent `
    -LineNumber $LineNumber
}

function Read-KwikenYamlMapping {
  param([Parameter(Mandatory = $true)][int]$Indent)

  $mapping = [ordered]@{}
  while ($true) {
    $line = MoveTo-KwikenYamlContent
    if ($null -eq $line -or $line.Indent -lt $Indent) { break }
    if ($line.Indent -ne $Indent -or $line.Content -match '^-\s*') {
      throw "Unexpected YAML mapping structure at line $($line.LineNumber)."
    }
    $script:KwikenYamlIndex++
    Add-KwikenYamlMappingEntry -Mapping $mapping -Content $line.Content `
      -Indent $Indent -LineNumber $line.LineNumber
  }
  return $mapping
}

function Read-KwikenYamlSequence {
  param([Parameter(Mandatory = $true)][int]$Indent)

  $sequence = [Collections.Generic.List[object]]::new()
  while ($true) {
    $line = MoveTo-KwikenYamlContent
    if ($null -eq $line -or $line.Indent -lt $Indent) { break }
    if ($line.Indent -ne $Indent -or $line.Content -cnotmatch '^-($|\s+)') {
      throw "Unexpected YAML sequence structure at line $($line.LineNumber)."
    }
    $itemText = $line.Content.Substring(1).TrimStart()
    $script:KwikenYamlIndex++
    if ([string]::IsNullOrEmpty($itemText)) {
      $next = MoveTo-KwikenYamlContent
      if ($null -eq $next -or $next.Indent -le $Indent) {
        $sequence.Add($null)
      } elseif ($next.Indent -eq $Indent + 2) {
        $sequence.Add((Read-KwikenYamlNode -Indent $next.Indent))
      } else {
        throw "Unexpected nested sequence indentation at line $($next.LineNumber)."
      }
      continue
    }
    if ($itemText -match '^[A-Za-z0-9_.-]+:(?: |$)') {
      $mappingIndent = $Indent + 2
      $mapping = [ordered]@{}
      Add-KwikenYamlMappingEntry -Mapping $mapping -Content $itemText `
        -Indent $mappingIndent -LineNumber $line.LineNumber
      while ($true) {
        $next = MoveTo-KwikenYamlContent
        if ($null -eq $next -or $next.Indent -le $Indent) { break }
        if ($next.Indent -ne $mappingIndent -or $next.Content -match '^-\s*') {
          throw "Unexpected sequence-mapping structure at line $($next.LineNumber)."
        }
        $script:KwikenYamlIndex++
        Add-KwikenYamlMappingEntry -Mapping $mapping -Content $next.Content `
          -Indent $mappingIndent -LineNumber $next.LineNumber
      }
      $sequence.Add($mapping)
    } else {
      $sequence.Add((ConvertFrom-KwikenYamlScalar `
          -Value $itemText -LineNumber $line.LineNumber))
      $next = MoveTo-KwikenYamlContent
      if ($null -ne $next -and $next.Indent -gt $Indent) {
        throw "Scalar sequence item has unexpected children at line $($next.LineNumber)."
      }
    }
  }
  return $sequence.ToArray()
}

function Read-KwikenYamlNode {
  param([Parameter(Mandatory = $true)][int]$Indent)

  $line = MoveTo-KwikenYamlContent
  if ($null -eq $line -or $line.Indent -ne $Indent) {
    throw "YAML node has invalid indentation."
  }
  if ($line.Content -cmatch '^-($|\s+)') {
    return Read-KwikenYamlSequence -Indent $Indent
  }
  return Read-KwikenYamlMapping -Indent $Indent
}

function ConvertFrom-KwikenWorkflowYaml {
  param([Parameter(Mandatory = $true)][string]$Text)

  if ($Text.IndexOf([char]9) -ge 0) {
    throw "YAML tab indentation is not supported."
  }
  foreach ($character in $Text.ToCharArray()) {
    if ([char]::IsControl($character) -and
        $character -ne "`r" -and $character -ne "`n") {
      throw "Workflow YAML contains a forbidden control character."
    }
  }
  $script:KwikenYamlLines = @($Text -split "`r?`n")
  $script:KwikenYamlIndex = 0
  $first = MoveTo-KwikenYamlContent
  if ($null -eq $first -or $first.Indent -ne 0) {
    throw "Workflow YAML must contain a root mapping."
  }
  $document = Read-KwikenYamlNode -Indent 0
  if ($null -ne (MoveTo-KwikenYamlContent)) {
    throw "Workflow YAML contains trailing unparsed content."
  }
  return $document
}

Assert-True -Condition (Test-Path -LiteralPath $workflowPath -PathType Leaf) `
  -Message "release.yml is missing."
Assert-True -Condition ($source.IndexOf([char]9) -lt 0) `
  -Message "release.yml must not contain YAML tab indentation."
Assert-NotMatch -Pattern '[ \t]+$' -Message "release.yml has trailing whitespace."
$workflow = ConvertFrom-KwikenWorkflowYaml -Text $source
Assert-True -Condition ($workflow -is [Collections.IDictionary]) `
  -Message "release.yml did not parse to a root YAML mapping."
$workflowJobs = $workflow["jobs"]
Assert-True -Condition ($workflowJobs -is [Collections.IDictionary] -and
    $workflowJobs.Count -eq 2 -and
    $workflowJobs.Contains("native-runtime") -and
    $workflowJobs.Contains("package-unsigned")) `
  -Message "Parsed workflow does not contain exactly the two reviewed jobs."
$nativeJob = $workflowJobs["native-runtime"]
$packageJob = $workflowJobs["package-unsigned"]
Assert-True -Condition ($nativeJob["steps"].Count -gt 0 -and
    $packageJob["steps"].Count -gt 0) `
  -Message "Parsed workflow jobs do not contain executable steps."
$metadataSteps = @($packageJob["steps"] | Where-Object {
    $_ -is [Collections.IDictionary] -and
      $_["name"] -ceq "Verify native artifact metadata"
  })
$packagingSteps = @($packageJob["steps"] | Where-Object {
    $_ -is [Collections.IDictionary] -and
      $_["name"] -ceq "Verify handoff and package unsigned candidate"
  })
Assert-True -Condition ($metadataSteps.Count -eq 1 -and
    $packagingSteps.Count -eq 1 -and
    $metadataSteps[0]["env"].Contains("ARTIFACT_API_TOKEN") -and
    -not $packagingSteps[0]["env"].Contains("ARTIFACT_API_TOKEN")) `
  -Message "Artifact metadata token must be isolated from every packaging tool."
Assert-True -Condition ($workflow["permissions"].Count -eq 0 -and
    $nativeJob["permissions"]["contents"] -ceq "read" -and
    $nativeJob["permissions"].Count -eq 1 -and
    $packageJob["permissions"]["actions"] -ceq "read" -and
    $packageJob["permissions"]["contents"] -ceq "read" -and
    $packageJob["permissions"].Count -eq 2) `
  -Message "Parsed workflow permissions exceed the reviewed read-only grants."
$malformedYamlRejected = $false
try {
  [void](ConvertFrom-KwikenWorkflowYaml -Text ($source + "`njobs: {}`n"))
} catch {
  $malformedYamlRejected = $_.Exception.Message.Contains("Duplicate YAML key 'jobs'")
}
Assert-True -Condition $malformedYamlRejected `
  -Message "Workflow YAML parser did not reject a duplicate root mapping key."
foreach ($invalidName in @(
    'name: @invalid',
    'name: &unsupported-anchor value',
    'name: {unsupported: flow-map}',
    "name: 'malformed'quote'"
  )) {
  $invalidScalarRejected = $false
  try {
    $invalidScalarSource = [regex]::Replace(
      $source,
      '(?m)^name:.*$',
      $invalidName,
      1
    )
    [void](ConvertFrom-KwikenWorkflowYaml -Text $invalidScalarSource)
  } catch {
    $invalidScalarRejected = $true
  }
  Assert-True -Condition $invalidScalarRejected `
    -Message "Workflow YAML parser accepted unsupported syntax: $invalidName"
}
foreach ($invalidMapping in @('x:y', 'x:#comment')) {
  $invalidMappingRejected = $false
  try {
    [void](ConvertFrom-KwikenWorkflowYaml -Text (
        $source + "`n$invalidMapping`n"
      ))
  } catch {
    $invalidMappingRejected = $true
  }
  Assert-True -Condition $invalidMappingRejected `
    -Message "Workflow YAML parser accepted a mapping colon without separation."
}
$invalidBlockIndentRejected = $false
try {
  [void](ConvertFrom-KwikenWorkflowYaml -Text (
      $source + "`nx: |`n    first`n   second`n"
    ))
} catch {
  $invalidBlockIndentRejected = $true
}
Assert-True -Condition $invalidBlockIndentRejected `
  -Message "Workflow YAML parser accepted inconsistent block-scalar indentation."
$invalidBlockControlRejected = $false
try {
  [void](ConvertFrom-KwikenWorkflowYaml -Text (
      $source + "`nx: |`n  ok$([char]0)bad`n"
    ))
} catch {
  $invalidBlockControlRejected = $true
}
Assert-True -Condition $invalidBlockControlRejected `
  -Message "Workflow YAML parser accepted a block-scalar control character."
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
  -Message "Both jobs must request contents:read."
Assert-True -Condition (([regex]::Matches(
      $source,
      '(?m)^\s{6}actions:\s+read\s*$'
    )).Count -eq 1) `
  -Message "Only the packaging job may read exact artifact metadata."
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
    "Verify native artifact metadata",
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
Assert-Contains -Needle '"sha256:$env:EXPECTED_ARTIFACT_DIGEST"' `
  -Message "Packager never compares the producer digest with GitHub artifact metadata."
Assert-Contains `
  -Needle "Producer artifact digest does not match GitHub's independent artifact metadata." `
  -Message "Packager does not fail closed on an independent artifact-digest mismatch."
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
    "KWIKEN_WINDOWS_SDK_ROOT",
    "KWIKEN_WEB_STORE_ARCHIVE",
    "KWIKEN_NSIS_RUNTIME_ROOT",
    "KWIKEN_NSIS_EXE_SHA256",
    "KWIKEN_NSIS_RUNTIME_TREE_SHA256"
  )) {
  $variableBinding = $variable + ': ${{ vars.' + $variable + ' }}'
  Assert-Contains -Needle $variableBinding `
    -Message "Controlled-runner variable is not explicit: $variable"
}
Assert-Contains -Needle 'KWIKEN_WINDOWS_SDK_ROOT is not provisioned on this runner.' `
  -Message "The controlled runner does not verify its extracted Windows SDK root."
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
  "-VisualStudioRoot",
  "-WindowsSdkRoot",
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
Assert-Contains -Needle 'launcherToolchain = $packagingToolchain' `
  -Message "Unsigned receipt does not bind the actual launcher packaging toolchain."
Assert-Contains -Needle 'Launcher toolchain does not match the explicitly approved roots.' `
  -Message "Packager does not validate the toolchain receipt against approved roots."
Assert-Contains -Needle 'Launcher resource compiler is not from the approved extracted SDK.' `
  -Message "Packager does not fail closed when rc.exe comes from another SDK."
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
Assert-True -Condition ($runBlocks -eq 8) `
  -Message "Unexpected workflow run-block count; update the contract intentionally."

Write-Output "release.yml parsed and fail-closed workflow contract tests passed."
