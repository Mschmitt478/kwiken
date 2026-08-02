# Kwiken Chromium Fork

Kwiken is a standalone Chromium browser, not an Electron shell. It keeps Chromium's full browser process model, sandbox, profiles, passwords, history, downloads, extensions, permissions, DevTools, and native Windows installer while applying Kwiken's product identity and vertical-tab interface.

## Pinned upstream

- Chromium `150.0.7871.186`
- Revision `0fcdce5f4fdec8d442d7df760cb541f1ca6e446d`
- Source checkout: `C:\src\kwiken-chromium\src`

The large Chromium checkout stays outside this repository. This directory contains only the reproducible patch set, build configuration, and packaging scripts.

For everyday installation, `scripts/build-distribution.ps1` packages the
matching GitHub Actions build of ungoogled-chromium-windows with Kwiken's
native launcher, vertical-tab defaults, resource branding, isolated profile,
Windows app registration, and installer. Its SHA-256 is pinned and verified
before packaging. The current Manifest V3 Chromium Web Store compatibility
extension is also checksum-pinned and bundled for Chrome, Edge, and Opera
extension-store installation. It requires extension-management and download
permissions to perform those installs and can be disabled with
`--disable-kwiken-web-store`.

## Build

Run from PowerShell:

```powershell
.\chromium-fork\scripts\bootstrap.ps1
.\chromium-fork\scripts\build.ps1 -Jobs 2
```

On a machine with limited memory, build the installable distribution without
waiting for the full local Chromium compile:

```powershell
.\chromium-fork\scripts\build-distribution.ps1
```

The distribution build requires Python 3, Visual Studio C++ build tools, and
NSIS. It downloads and verifies the pinned Chromium runtime automatically and
does not require the external Chromium source checkout.

The installer is written to `chromium-fork\release\Kwiken-Setup-150.0.7871.186-r4.exe`.

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
