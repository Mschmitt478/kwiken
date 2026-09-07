$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$forkRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $forkRoot "scripts\build-distribution.ps1"
$source = Get-Content -LiteralPath $scriptPath -Raw
$installerPath = Join-Path $forkRoot "distribution\installer\Kwiken.nsi"
$installerSource = Get-Content -LiteralPath $installerPath -Raw
$launcherPath = Join-Path $forkRoot "distribution\launcher\KwikenLauncher.cpp"
$launcherSource = Get-Content -LiteralPath $launcherPath -Raw
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  $scriptPath,
  [ref]$tokens,
  [ref]$parseErrors
)
if ($parseErrors.Count -ne 0) {
  throw "build-distribution.ps1 has parser errors: $($parseErrors -join '; ')"
}

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

function Assert-NotContains {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Needle,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )
  Assert-True -Condition ($source.IndexOf(
      $Needle,
      [StringComparison]::OrdinalIgnoreCase
    ) -lt 0) -Message $Message
}

$explicitInputs = @(
  "RuntimeReadyPath",
  "RuntimeArchive",
  "RuntimeManifest",
  "ExpectedReadySha256",
  "WebStoreArchive",
  "PythonPath",
  "PythonRuntimeRoot",
  "ExpectedPythonSha256",
  "ExpectedPythonRuntimeTreeSha256",
  "VisualStudioRoot",
  "WindowsSdkRoot",
  "MakeNsisPath",
  "MakeNsisRuntimeRoot",
  "ExpectedMakeNsisSha256",
  "ExpectedMakeNsisRuntimeTreeSha256"
)
$parameters = @{}
foreach ($parameter in $ast.ParamBlock.Parameters) {
  $parameters[$parameter.Name.VariablePath.UserPath] = $parameter
}
foreach ($name in $explicitInputs) {
  Assert-True -Condition $parameters.ContainsKey($name) `
    -Message "The distribution bridge is missing the explicit $name input."
  Assert-True -Condition ($null -eq $parameters[$name].DefaultValue) `
    -Message "$name must not have an implicit/default input."
  $parameterText = $parameters[$name].Extent.Text
  Assert-True -Condition ($parameterText -match 'Mandatory\s*=\s*\$true') `
    -Message "$name must be mandatory."
}

Assert-NotContains -Needle '"-latest"' `
  -Message "The distribution bridge still selects an implicit latest Visual Studio."
Assert-Contains -Needle '-VisualStudioRoot $visualStudioRootInput.FullName' `
  -Message "The explicitly approved Visual Studio root is not validated."
Assert-Contains -Needle '"bin\$approvedSdkVersion\x64\rc.exe"' `
  -Message "The resource compiler is not selected from the explicit Windows SDK root."
Assert-Contains -Needle '-winsdk=none' `
  -Message "VsDevCmd may still inject an unapproved installed Windows SDK."
Assert-Contains -Needle 'The explicitly approved launcher toolchain changed during compilation.' `
  -Message "Launcher compiler/linker/resource tools are not protected against replacement."
Assert-Contains -Needle 'PackagingToolchain = $packagingToolchain' `
  -Message "The distribution result does not expose launcher toolchain provenance."

$fixtureFunctions = @(
  "Assert-NoReparsePath",
  "Get-RegularFile",
  "Get-RegularDirectory",
  "Assert-FileWithinRoot",
  "Get-ApprovedVisualStudioDirectories",
  "Import-VisualStudioEnvironment"
)
$fixtureFunctionSource = foreach ($functionName in $fixtureFunctions) {
  $definition = $ast.Find(
    {
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq $functionName
    },
    $true
  )
  Assert-True -Condition ($null -ne $definition) `
    -Message "Could not inspect distribution function $functionName."
  $definition.Extent.Text
}
. ([scriptblock]::Create(($fixtureFunctionSource -join "`n`n")))

function Invoke-BoundedProcess {
  return [pscustomobject]@{
    StandardOutput = @(
      "PATH=$script:FixtureVisualStudio\bin;C:\Windows\System32",
      "INCLUDE=$script:FixtureVisualStudio\include",
      "EXTERNAL_INCLUDE=$script:FixtureVisualStudio\external-include",
      "LIB=$script:FixtureVisualStudio\lib",
      "LIBPATH=$script:FixtureVisualStudio\libpath;C:\Windows\Microsoft.NET\Framework64\v4.0.30319",
      "CL=/FI C:\UNAPPROVED-SDK\forced.h",
      "_CL_=/DUNAPPROVED=1",
      "LINK=/LIBPATH:C:\UNAPPROVED-SDK",
      "_LINK_=/OUT:C:\UNAPPROVED-SDK\Kwiken.exe"
    ) -join "`r`n"
    StandardError = ""
    ExitCode = 0
  }
}

$script:RequiredWindowsSdkVersion = [Version]"10.0.28000.0"
$toolchainFixture = Join-Path ([IO.Path]::GetTempPath()) `
  ("Kwiken-Distribution-Toolchain-Test-" + [Guid]::NewGuid().ToString("N"))
try {
  $fixtureVisualStudio = Join-Path $toolchainFixture "vs"
  $script:FixtureVisualStudio = $fixtureVisualStudio
  $fixtureSdk = Join-Path $toolchainFixture "sdk"
  $fixtureWork = Join-Path $toolchainFixture "work"
  foreach ($directory in @(
      (Join-Path $fixtureVisualStudio "Common7\Tools"),
      (Join-Path $fixtureVisualStudio "bin"),
      (Join-Path $fixtureVisualStudio "include"),
      (Join-Path $fixtureVisualStudio "external-include"),
      (Join-Path $fixtureVisualStudio "lib"),
      (Join-Path $fixtureVisualStudio "libpath"),
      (Join-Path $fixtureSdk "bin\10.0.28000.0\x64"),
      (Join-Path $fixtureSdk "Include\10.0.28000.0\ucrt"),
      (Join-Path $fixtureSdk "Include\10.0.28000.0\shared"),
      (Join-Path $fixtureSdk "Include\10.0.28000.0\um"),
      (Join-Path $fixtureSdk "Include\10.0.28000.0\winrt"),
      (Join-Path $fixtureSdk "Include\10.0.28000.0\cppwinrt"),
      (Join-Path $fixtureSdk "Lib\10.0.28000.0\ucrt\x64"),
      (Join-Path $fixtureSdk "Lib\10.0.28000.0\um\x64"),
      $fixtureWork
    )) {
    [void][IO.Directory]::CreateDirectory($directory)
  }
  [IO.File]::WriteAllText(
    (Join-Path $fixtureVisualStudio "Common7\Tools\VsDevCmd.bat"),
    "@exit /b 0`r`n",
    [Text.Encoding]::ASCII
  )
  $fixtureEnvironment = Import-VisualStudioEnvironment `
    -WorkDirectory $fixtureWork -VisualStudioRoot $fixtureVisualStudio `
    -WindowsSdkRoot $fixtureSdk
  Assert-True -Condition ($fixtureEnvironment["WINDOWSSDKDIR"] -ceq
      $fixtureSdk.TrimEnd('\') + '\') `
    -Message "Extracted SDK root was not installed into the launcher environment."
  Assert-True -Condition ($fixtureEnvironment["WindowsSDKVersion"] -ceq
      "10.0.28000.0\") `
    -Message "Launcher environment does not pin the exact SDK version."
  Assert-True -Condition ($fixtureEnvironment["PATH"].StartsWith(
      (Join-Path $fixtureSdk "bin\10.0.28000.0\x64") + ';',
      [StringComparison]::OrdinalIgnoreCase
    )) -Message "Extracted SDK tools are not first in the launcher PATH."
  Assert-True -Condition ($fixtureEnvironment["INCLUDE"].Contains(
      (Join-Path $fixtureSdk "Include\10.0.28000.0\winrt")
    ) -and $fixtureEnvironment["INCLUDE"].Contains(
      (Join-Path $fixtureSdk "Include\10.0.28000.0\cppwinrt")
    )) -Message "Extracted SDK WinRT headers are missing from launcher INCLUDE."
  Assert-True -Condition ($fixtureEnvironment["LIBPATH"].IndexOf(
      "C:\Windows\Microsoft.NET",
      [StringComparison]::OrdinalIgnoreCase
    ) -lt 0) -Message "Launcher LIBPATH retained a directory outside the approved VS root."
  foreach ($optionName in @("CL", "_CL_", "LINK", "_LINK_", "RC", "_RC_")) {
    Assert-True -Condition ([string]$fixtureEnvironment[$optionName] -ceq "") `
      -Message "Launcher environment retained inherited $optionName options."
  }
  $environmentLoader = Get-Content `
    (Join-Path $fixtureWork "load-vs-environment.cmd") -Raw
  Assert-True -Condition $environmentLoader.Contains("-winsdk=none") `
    -Message "Launcher environment did not disable VsDevCmd SDK auto-selection."
  foreach ($clearedName in @(
      "CL", "_CL_", "LINK", "_LINK_", "RC", "_RC_",
      "INCLUDE", "EXTERNAL_INCLUDE", "LIB", "LIBPATH"
    )) {
    Assert-True -Condition $environmentLoader.Contains("set $clearedName=") `
      -Message "VsDevCmd inherits unapproved $clearedName from the runner."
  }
  $unapprovedIncludeRejected = $false
  try {
    [void](Get-ApprovedVisualStudioDirectories -Environment @{
        INCLUDE = "$fixtureVisualStudio\include;C:\UNAPPROVED-SDK\include"
      } -Name "INCLUDE" -VisualStudioRoot $fixtureVisualStudio)
  } catch {
    $unapprovedIncludeRejected = $true
  }
  Assert-True -Condition $unapprovedIncludeRejected `
    -Message "Launcher INCLUDE accepted a directory outside the approved VS root."

  [IO.Directory]::Delete(
    (Join-Path $fixtureSdk "Lib\10.0.28000.0\um\x64")
  )
  $missingSdkComponentRejected = $false
  try {
    [void](Import-VisualStudioEnvironment `
        -WorkDirectory $fixtureWork -VisualStudioRoot $fixtureVisualStudio `
        -WindowsSdkRoot $fixtureSdk)
  } catch {
    $missingSdkComponentRejected = $true
  }
  Assert-True -Condition $missingSdkComponentRejected `
    -Message "Launcher packaging did not fail closed for an incomplete extracted SDK."
} finally {
  $script:FixtureVisualStudio = $null
  $resolvedFixture = [IO.Path]::GetFullPath($toolchainFixture)
  $fixturePrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') +
    '\Kwiken-Distribution-Toolchain-Test-'
  if (-not $resolvedFixture.StartsWith(
      $fixturePrefix,
      [StringComparison]::OrdinalIgnoreCase
    )) {
    throw "Refusing to clean an unexpected toolchain fixture path."
  }
  if (Test-Path -LiteralPath $resolvedFixture) {
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
  }
}

foreach ($legacy in @(
    "ungoogled-chromium",
    "rcedit",
    "rebrand_paks.py",
    "curl.exe",
    "tar.exe",
    "Invoke-WebRequest",
    "Start-BitsTransfer",
    "System.Net.WebClient",
    "LICENSE.ungoogled",
    "LICENSE.rcedit"
  )) {
  Assert-NotContains -Needle $legacy `
    -Message "The legacy downloadable/rebrand path remains in build-distribution.ps1: $legacy"
}

Assert-Contains -Needle 'Runtime READY SHA-256 does not match the trusted value.' `
  -Message "The external READY trust anchor is not enforced."
Assert-Contains -Needle 'Assert-ExactProperties -Object $ready' `
  -Message "READY schema is not closed before use."
Assert-Contains -Needle 'READY, runtime archive, and runtime manifest must share one release directory.' `
  -Message "The exported release handoff is not kept together."
Assert-Contains -Needle 'export-runtime.ps1''s canonical file names' `
  -Message "Canonical export-runtime file names are not enforced."

$readyAuthentication = $source.IndexOf(
  'Get-LowerSha256 -Path $readySnapshot',
  [StringComparison]::Ordinal
)
$readyParse = $source.IndexOf(
  '$ready = Read-BoundedJson',
  [StringComparison]::Ordinal
)
$manifestAuthentication = $source.IndexOf(
  'Get-LowerSha256 -Path $manifestSnapshot',
  [StringComparison]::Ordinal
)
$manifestParse = $source.IndexOf(
  '$manifest = Read-BoundedJson',
  [StringComparison]::Ordinal
)
Assert-True -Condition ($readyAuthentication -ge 0 -and
    $readyParse -gt $readyAuthentication) `
  -Message "READY must be authenticated before it is parsed."
Assert-True -Condition ($manifestAuthentication -ge 0 -and
    $manifestParse -gt $manifestAuthentication) `
  -Message "The manifest must be authenticated by READY before it is parsed."

$verifyFlags = @(
  "--archive",
  "--manifest",
  "--extract-to",
  "--expect-version",
  "--expect-package-revision",
  "--expect-release-version",
  "--expect-kwiken-revision",
  "--expect-chromium-revision",
  "--expect-depot-tools-revision",
  "--expect-source-delta-sha256",
  "--expect-dependency-state-tree-sha256",
  "--expect-gn-args-sha256",
  "--expect-artifact-sha256",
  "--expect-artifact-size",
  "--expect-chrome-7z-sha256",
  "--expect-chrome-exe-sha256",
  "--expect-mini-installer-sha256",
  "--expect-build-command-line",
  "--expect-build-jobs",
  "--expect-output-directory",
  "--expect-visual-studio-version",
  "--expect-windows-sdk-version",
  "--expect-windows-debugger-version",
  "--expect-python-version",
  "--expect-python-cipd-package",
  "--expect-python-cipd-version",
  "--expect-python-cipd-instance",
  "--expect-cipd-client-version",
  "--expect-cipd-client-sha256",
  "--expect-python-path",
  "--expect-python-runtime-tree-sha256",
  "--expect-python-sha256",
  "--expect-seven-zip-path",
  "--expect-seven-zip-sha256",
  "--expect-source-input",
  "--require-clean-source",
  "--max-files",
  "--max-uncompressed-bytes",
  "--max-archive-bytes"
)
foreach ($flag in $verifyFlags) {
  Assert-Contains -Needle ('"' + $flag + '"') `
    -Message "Strict runtime verification is missing $flag."
}
Assert-Contains -Needle '"-I", "-S", "-B", $runtimeArchiveTool, "verify"' `
  -Message "runtime_archive.py is not invoked with isolated Python."
Assert-Contains -Needle '-Description "strict native runtime verification/extraction" -IsolatedPython' `
  -Message "Runtime verification/extraction is not a single bounded operation."
Assert-Contains -Needle '$script:ExpectedSourceDeltaSha256' `
  -Message "The source-delta expectation is not anchored to this checkout."
Assert-Contains -Needle '$script:DepotToolsRevision' `
  -Message "The depot_tools expectation is not anchored to this checkout."
Assert-Contains -Needle '$script:Revision' `
  -Message "The Chromium expectation is not anchored to this checkout."

Assert-Contains -Needle 'CreateKillOnClose' `
  -Message "External packaging tools are not assigned to a kill-on-close job."
Assert-Contains -Needle 'KWIKEN_DISTRIBUTION_GATE' `
  -Message "The process-job admission gate is missing."
Assert-Contains -Needle 'MaximumProcessOutputBytes' `
  -Message "External process output is not bounded."
Assert-Contains -Needle 'AddSeconds($ProcessTimeoutSeconds)' `
  -Message "External process time is not bounded."
Assert-Contains -Needle 'StartsWith("PYTHON"' `
  -Message "Verifier Python environment variables are not isolated."

Assert-Contains -Needle 'KwikenDistributionPrivateDirectory' `
  -Message "Private distribution staging is not created with an atomic security descriptor."
Assert-Contains -Needle 'D:P(A;OICI;FA;;;{0})(A;OICI;FA;;;SY)' `
  -Message "Private distribution staging does not use a protected owner/SYSTEM ACL."
Assert-Contains -Needle 'Copy-InputSnapshot' `
  -Message "Distribution inputs are not snapshotted before use."
Assert-Contains -Needle '[IO.FileMode]::CreateNew' `
  -Message "Snapshot/publication writes can overwrite existing files."
Assert-Contains -Needle '[IO.File]::Move($publishTemporary, $installerPath)' `
  -Message "The public installer is not atomically committed."
Assert-Contains -Needle 'Refusing to overwrite the public Kwiken installer' `
  -Message "Public installer publication can overwrite an existing artifact."
$commandNames = @($ast.FindAll(
    { param($node) $node -is [Management.Automation.Language.CommandAst] },
    $true
  ) | ForEach-Object { $_.GetCommandName() })
Assert-True -Condition ($commandNames -notcontains "Move-Item") `
  -Message "The distribution bridge must not use force-capable Move-Item publication."

Assert-Contains -Needle '$script:ExpectedWebStoreSha256' `
  -Message "The compatible Web Store extension is not checksum pinned."
Assert-Contains -Needle 'Expand-PinnedWebStoreArchive' `
  -Message "The pinned Web Store extension is not safely staged."
Assert-Contains -Needle 'manifest_version' `
  -Message "The Web Store extension's MV3 manifest is not validated."
Assert-Contains -Needle 'LICENSE.chromium.txt' `
  -Message "Chromium license is not included."
Assert-Contains -Needle 'LICENSE.chromium-web-store.txt' `
  -Message "Web Store extension license is not included."
Assert-Contains -Needle 'Runtime provenance: provenance\$expectedManifestName' `
  -Message "The installer does not carry its authenticated runtime provenance."

Assert-Contains -Needle 'KwikenLauncher.cpp' `
  -Message "The native launcher is no longer packaged."
Assert-Contains -Needle 'Kwiken.nsi' `
  -Message "The NSIS installer is no longer packaged."
$initialPreferencesMatch = [regex]::Match(
  $launcherSource,
  '(?s)constexpr char kInitialPreferences\[\] = R"json\((?<json>.*?)\)json";'
)
Assert-True -Condition $initialPreferencesMatch.Success `
  -Message "The launcher default profile preferences are not inspectable."
$initialPreferences = $initialPreferencesMatch.Groups['json'].Value |
  ConvertFrom-Json
Assert-True -Condition (
    $initialPreferences.extensions.theme.id -eq 'user_color_theme_id'
  ) -Message "New profiles must start with Chromium's user-color theme enabled."
Assert-True -Condition (
    $initialPreferences.browser.theme.user_color2 -eq -4729771
  ) -Message "New profiles no longer default to Kwiken olive #B7D455."
Assert-True -Condition (
    $initialPreferences.browser.theme.color_variant2 -eq 2
  ) -Message "Kwiken's default olive theme must use Chromium's Neutral variant."
Assert-True -Condition (
    $initialPreferences.browser.theme.color_scheme2 -eq 1
  ) -Message "Kwiken's default olive theme must start in the light scheme."
$chromeInstallFilesSid =
  'S-1-15-3-1024-3424233489-972189580-2057154623-747635277-1604371224-' +
  '316187997-3786583170-1043257646'
$lpacChromeInstallFilesSid =
  'S-1-15-3-1024-2302894289-466761758-1166120688-1039016420-2430351297-' +
  '4240214049-4028510897-3317428798'
foreach ($sid in @($chromeInstallFilesSid, $lpacChromeInstallFilesSid)) {
  Assert-True -Condition ($installerSource.Contains($sid)) `
    -Message "The installer is missing Chromium sandbox capability SID $sid."
}
Assert-True -Condition (([regex]::Matches(
      $installerSource,
      [regex]::Escape('/grant:r')
    )).Count -eq 2) `
  -Message "The installer must configure exactly two sandbox capability ACLs."
Assert-True -Condition (([regex]::Matches(
      $installerSource,
      [regex]::Escape('(OI)(CI)(RX)')
    )).Count -eq 2) `
  -Message "Both sandbox capability ACLs must be inherited read/execute only."
$sandboxAclCommands = @($installerSource -split "`r?`n" | Where-Object {
    $_.Contains('/grant:r')
  })
foreach ($command in $sandboxAclCommands) {
  Assert-True -Condition ($command -notmatch '\((?:W|M|F)\)') `
    -Message "Sandbox capability ACLs must never grant write, modify, or full control."
}
Assert-True -Condition ($installerSource.Contains(
    'nsExec::ExecToStack /TIMEOUT=120000'
  )) -Message "Sandbox ACL configuration is not bounded or exit-code checked."
$payloadExtraction = $installerSource.IndexOf(
  'File /r "${STAGING}\*"',
  [StringComparison]::Ordinal
)
$sandboxAclCall = $installerSource.IndexOf(
  'Call GrantSandboxCapabilityAccess',
  [StringComparison]::Ordinal
)
$firstLaunch = $installerSource.IndexOf(
  'ExecWait ''"$INSTDIR\Kwiken.exe" --repair-shortcuts''',
  [StringComparison]::Ordinal
)
Assert-True -Condition ($payloadExtraction -ge 0 -and
    $sandboxAclCall -gt $payloadExtraction -and
    $firstLaunch -gt $sandboxAclCall) `
  -Message "Sandbox ACLs must be applied after extraction and before first launch."
Assert-True -Condition ($installerSource.Contains('SetErrorLevel 1') -and
    $installerSource.Contains("`n  Abort")) `
  -Message "The installer must fail closed when sandbox ACL setup fails."
Assert-Contains -Needle 'Kwiken-Setup-$script:ReleaseVersion.exe' `
  -Message "The public installer naming contract changed."
Assert-Contains -Needle 'Signed = $false' `
  -Message "Unsigned output is not explicitly disclosed."
Assert-Contains -Needle 'Verifier Python SHA-256 does not match the trusted value.' `
  -Message "Verifier Python is not independently authenticated."
Assert-Contains -Needle 'Get-DirectoryTreeSha256 -Root $pythonSnapshotRoot' `
  -Message "The complete verifier Python runtime is not authenticated after snapshot."
Assert-Contains -Needle 'pinned runtime authenticated by READY' `
  -Message "Verifier Python is not bound to the authenticated native-build provenance."
Assert-Contains -Needle 'makensis.exe SHA-256 does not match the trusted value.' `
  -Message "NSIS is not independently authenticated."
Assert-Contains -Needle 'Get-DirectoryTreeSha256 -Root $makeNsisSnapshotRoot' `
  -Message "The complete private NSIS runtime is not tree-hash authenticated."

Write-Output "build-distribution.ps1 contract tests passed."
