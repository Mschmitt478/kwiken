# Kwiken Chromium Fork

Kwiken is a standalone Chromium browser, not an Electron shell. It keeps Chromium's full browser process model, sandbox, profiles, passwords, history, downloads, extensions, permissions, DevTools, and native Windows installer while applying Kwiken's product identity and vertical-tab interface.

## Pinned upstream

- Chromium `150.0.7871.186`
- Revision `0fcdce5f4fdec8d442d7df760cb541f1ca6e446d`
- depot_tools revision `5b785272f9c776789167b4a8e32eab34352e6f20`
- Source checkout: `C:\src\kwiken-chromium\src`

The large Chromium checkout stays outside this repository. This directory contains only the reproducible patch set, build configuration, and packaging scripts.

For everyday installation, `scripts/build-distribution.ps1` packages only a
native Kwiken runtime produced by `scripts/export-runtime.ps1`. An explicitly
trusted hash authenticates the export's `RELEASE.READY.json`; READY binds the
runtime ZIP and provenance manifest, and the complete provenance/content
contract is verified again before the runtime is extracted. The distribution
adds Kwiken's native launcher, isolated profile, Windows app registration, and
NSIS installer without rewriting the already branded Chromium binaries or
resource packs. The current Manifest V3 Chromium Web Store compatibility
extension remains checksum-pinned and bundled for Chrome, Edge, and Opera
extension-store installation. It requires extension-management and download
permissions to perform those installs and can be disabled with
`--disable-kwiken-web-store`.

## Build

Chromium 150 requires Visual Studio 2026 with Desktop development with C++,
ATL/MFC, Windows 11 SDK 10.0.26100.7705 or newer, and Windows SDK Debugging
Tools 10.0.26100.3323 or newer. Check the host before downloading Chromium:

```powershell
.\chromium-fork\scripts\preflight.ps1
```

Then bootstrap and build from PowerShell:

```powershell
.\chromium-fork\scripts\bootstrap.ps1
.\chromium-fork\scripts\build.ps1 -Jobs 2
.\chromium-fork\scripts\launch.ps1 -TemporaryProfile
```

The launcher waits up to 30 seconds for a visible browser window and rejects an
early crash or handoff. Increase `-StartupTimeoutSeconds` on a slower host.
`-AdditionalArguments` preserves individual values containing spaces, quotes,
or trailing backslashes; use `-PassThru` when an automation needs the validated
browser `Process` object.

Bootstrap limits `gclient` to four concurrent source fetches and retries a
partial sync when Chromium's anonymous Git service applies a short-term rate
limit. Use `-SyncJobs` or `-SyncAttempts` to tune those bounded retries; rerun
the same command to resume an interrupted checkout without deleting it.

The default external roots are `C:\src\kwiken-chromium` and
`C:\src\depot_tools`. Override them with `-ChromiumRoot` /
`-DepotToolsRoot` or the `KWIKEN_CHROMIUM_ROOT` /
`KWIKEN_DEPOT_TOOLS_ROOT` environment variables. A non-default Visual Studio
installation can be selected with `-VisualStudioRoot` or
`KWIKEN_VISUAL_STUDIO_ROOT`.

The scripts pin both Chromium and depot_tools, prepend depot_tools only for the
build process, and apply Chromium's required Git settings without changing the
user's global Git configuration or leaving process-level overrides behind.
The complete reviewed Chromium source delta (patch, string transformation, and
canonical brand assets) is fingerprinted by `SOURCE_DELTA_SHA256`; unexpected
tracked edits stop the build. Brand PNG/ICO files are copied byte-for-byte from
`assets` rather than rasterized with host fonts or GDI+. Run
`preflight.ps1 -Stage Build` after the
checkout to verify the pinned checkout and complete incremental-build
environment.

The full source build places Chromium's diagnostic native installer under
`release\native\Kwiken-Native-MiniInstaller-<version>.exe`. It deliberately
does not use the public `Kwiken-Setup-*` name owned by the launcher/NSIS
distribution path.

The no-dependency script checks can be run in Windows PowerShell or PowerShell
7:

```powershell
.\chromium-fork\tests\build-scripts.tests.ps1
.\chromium-fork\tests\build-distribution.tests.ps1
.\chromium-fork\tests\release-workflow.tests.ps1
```

First export a clean, fully validated native runtime. The export is published
as a new, immutable directory containing `RELEASE.READY.json`, the runtime ZIP,
and its provenance manifest:

```powershell
$runtime = .\chromium-fork\scripts\export-runtime.ps1 -Jobs 2
```

That export can be handed to a lower-memory packaging machine; the Chromium
checkout is not needed there. Supply every handoff path explicitly, together
with the READY, Python, and NSIS hashes approved by the producing environment.
For a local build, the hashes can be captured immediately from those trusted
outputs:

```powershell
function Get-KwikenToolTreeSha256([string]$Root) {
  $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  $paths = @(Get-ChildItem $rootPath -File -Recurse -Force |
    ForEach-Object { $_.FullName.Substring($rootPath.Length + 1).Replace('\', '/') })
  [Array]::Sort($paths, [StringComparer]::Ordinal)
  $records = [IO.MemoryStream]::new()
  $sha256 = [Security.Cryptography.SHA256]::Create()
  foreach ($path in $paths) {
    $file = Get-Item (Join-Path $rootPath $path.Replace('/', '\'))
    $hash = (Get-FileHash $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes(
      "$path$([char]0)$($file.Length)$([char]0)$hash`n"
    )
    $records.Write($bytes, 0, $bytes.Length)
  }
  $records.Position = 0
  -join ($sha256.ComputeHash($records) | ForEach-Object { $_.ToString('x2') })
  $sha256.Dispose()
  $records.Dispose()
}

$provenance = Get-Content $runtime.ManifestPath -Raw | ConvertFrom-Json
$depotToolsRoot = "C:\src\depot_tools"
$python = Join-Path $depotToolsRoot `
  $provenance.nativeBuild.toolchain.pythonPath.Replace('/', '\')
$pythonRoot = Split-Path -Parent $python
$nsisRoot = "C:\tools\kwiken-nsis-3.12\nsis-3.12"
$makensis = Join-Path $nsisRoot "makensis.exe"
$readySha256 = (Get-FileHash $runtime.ReadyPath -Algorithm SHA256).Hash
$pythonSha256 = $provenance.nativeBuild.toolchain.pythonSha256
$pythonTreeSha256 = $provenance.nativeBuild.toolchain.pythonRuntimeTreeSha256
$makensisSha256 = (Get-FileHash $makensis -Algorithm SHA256).Hash
$makensisTreeSha256 = Get-KwikenToolTreeSha256 $nsisRoot

.\chromium-fork\scripts\build-distribution.ps1 `
  -RuntimeReadyPath $runtime.ReadyPath `
  -RuntimeArchive $runtime.ArchivePath `
  -RuntimeManifest $runtime.ManifestPath `
  -ExpectedReadySha256 $readySha256 `
  -WebStoreArchive C:\tools\kwiken-inputs\chromium-web-store-v1.5.5.3.zip `
  -PythonPath $python `
  -PythonRuntimeRoot $pythonRoot `
  -ExpectedPythonSha256 $pythonSha256 `
  -ExpectedPythonRuntimeTreeSha256 $pythonTreeSha256 `
  -MakeNsisPath $makensis `
  -MakeNsisRuntimeRoot $nsisRoot `
  -ExpectedMakeNsisSha256 $makensisSha256 `
  -ExpectedMakeNsisRuntimeTreeSha256 $makensisTreeSha256
```

For a transferred runtime, obtain the expected hashes through a trusted build
record or other authenticated channel; calculating the READY hash from the
same untrusted bundle would not authenticate it. The Web Store source archive
must be the pinned `v1.5.5.3` archive (SHA-256
`627cb80dd67d16e4d2a9f105c1a1c5adf61dca63202bd577a4e4af84bd07868c`).
The approved source is the immutable GitHub tag archive at
`https://github.com/NeverDecaf/chromium-web-store/archive/refs/tags/v1.5.5.3.zip`.
The approved NSIS input is the official `nsis-3.12.zip` portable release from
SourceForge (archive SHA-256
`56581f90db321581c5381193d796fffcf2d24b2f8fed2160a6c6a3baa67f2c4f`).
For an unchanged extraction of that archive, the direct-child `makensis.exe`
SHA-256 is
`b043e554afefbfc56315669d0b4779793aeae67f0f2a7a790e2ea91f05298eff`
and the runtime tree SHA-256 produced by `Get-KwikenToolTreeSha256` is
`09638d073c434a597a82c4197aded0582340b0a45598c2613e3f8459b6b733d8`.
Provision and review these inputs outside the release job; the workflow never
downloads executable toolchains or accepts a mutable latest-version URL.
The distribution build does not download or modify browser binaries. It
requires the same pinned Python runtime recorded by the authenticated native
build, Visual Studio C++ build tools, and NSIS. The complete Python runtime is
copied into private staging and tree-hash verified before it runs the archive
validator. The complete NSIS runtime is handled the same way before it creates
the installer.

The installer is written to `chromium-fork\release\Kwiken-Setup-150.0.7871.186-r5.exe`.
This local artifact is deliberately reported as unsigned; Authenticode signing
and release attestation remain required before public distribution.

## Unsigned candidate workflow

`.github/workflows/release.yml` is a manual, fail-closed build pipeline. It has
only a `workflow_dispatch` trigger, rejects non-default-branch dispatches, and
targets runners with all four labels
`self-hosted`, `Windows`, `X64`, and `kwiken-chromium`. If such a controlled
runner is not registered, the workflow remains queued; it does not fall back to
a GitHub-hosted image.

The controlled runner must use GitHub Actions Runner 2.327.1 or newer for the
pinned Node 24 actions, PowerShell 7, Git, Visual Studio 2026 with the required
C++/SDK/debugger components, sufficient Chromium build capacity, and these
repository variables:

- `KWIKEN_CHROMIUM_ROOT`: persistent dedicated Chromium checkout root.
- `KWIKEN_DEPOT_TOOLS_ROOT`: persistent pinned depot_tools root.
- `KWIKEN_VISUAL_STUDIO_ROOT`: approved Visual Studio 18 installation.
- `KWIKEN_WEB_STORE_ARCHIVE`: pre-provisioned `v1.5.5.3` source ZIP; its
  fixed SHA-256 is verified by both the workflow and distribution bridge.
- `KWIKEN_NSIS_RUNTIME_ROOT`: pre-provisioned approved NSIS directory.
- `KWIKEN_NSIS_EXE_SHA256`: independently reviewed `makensis.exe` hash.
- `KWIKEN_NSIS_RUNTIME_TREE_SHA256`: independently reviewed full NSIS tree
  hash using the same record format shown above.

If the custom label selects a runner pool, every matching runner must carry the
same approved tool paths and hashes; the native and packaging jobs are allowed
to land on different members of that pool. Restrict that runner group to this
repository and trusted maintainers because the job executes the selected
default-branch commit and maintains a persistent Chromium checkout.

The first job checks out the exact workflow commit, runs bootstrap/build
preflights, exports and smoke-tests the native runtime, and uploads READY, the
runtime archive, provenance, and the exact provenance-bound Python runtime.
The second job downloads that exact artifact ID, retains its service digest
and producer READY hash, verifies every source/tool input, and uploads only an
unsigned installer plus `UNSIGNED.NOT-FOR-PUBLICATION.json`. Both jobs have
only `contents: read`; the workflow has no release, tag, signing, credential,
or overwrite path.

A separate workflow is still required and intentionally not stubbed here. It
must consume the unsigned artifact by immutable ID/digest behind an approved
GitHub Environment, Authenticode-sign it with externally managed credentials,
verify the signature and final hash, create provenance/attestation, and only
then publish a new immutable release. Until that gate is configured, workflow
artifacts are validation candidates, not releases.

The packaged runtime is a complete standalone Chromium browser, not Electron,
CEF, or an embedded webview. Website sign-in therefore uses a normal top-level
browser context. Browser-level Chrome Sync remains unavailable without
Google's private API credentials.

## Authentication behavior

Google website sign-in runs as a normal top-level Chromium navigation, so it does not use Electron's blocked embedded OAuth user agent. Kwiken deliberately does not embed a private Chrome OAuth client ID or secret. Browser-level Chrome Sync is therefore not offered; website sessions, local profiles, local passwords, passkeys, and extension-owned OAuth continue to work normally.

## Current product defaults

- Native vertical tabs enabled at first launch
- 260-pixel expanded tab rail
- Kwiken olive, paper, and lime color system
- DuckDuckGo default search
- Restore the previous session
- Do Not Track enabled
- Aggressive Memory Saver enabled for new profiles
- Speculative page preloading and background residency disabled
- Idle spare renderer disabled; restore with `--enable-kwiken-spare-renderer`
- H.264/AAC/MP4 codec build flags enabled
- Separate `%LOCALAPPDATA%\Kwiken` install and profile paths
- Bundled Chromium Web Store compatibility extension; disable with `--disable-kwiken-web-store`

Widevine DRM is not bundled because Google licenses its binary CDM separately from Chromium.
