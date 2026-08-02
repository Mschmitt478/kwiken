<p align="center">
  <img src="chromium-fork/assets/kwiken-icon.png" alt="Kwiken" width="128">
</p>

<h1 align="center">Kwiken</h1>

<p align="center">
  A calm, lightweight Windows browser with native vertical tabs, built on the
  complete Chromium browser engine rather than Electron or an embedded webview.
</p>

![Kwiken browser with native vertical tabs](chromium-fork/assets/kwiken-browser.png)

## Install

Download `Kwiken-Setup-150.0.7871.186-r4.exe` from the latest GitHub release.
Kwiken installs per-user, creates Start menu and desktop shortcuts, registers
itself with Windows Default Apps, and keeps its profile in
`%LOCALAPPDATA%\Kwiken\User Data`.

The current installer is not code-signed, so Windows SmartScreen may show an
unknown-publisher warning. The release notes include its SHA-256 checksum.

## Browser Features

- Complete Chromium multi-process architecture and sandbox
- Native vertical tabs enabled on first launch
- Local profiles, history, bookmarks, passwords, passkeys, downloads, and DevTools
- Chromium extension support and normal website permissions
- Chrome, Edge, and Opera extension-store installation through a bundled open-source bridge
- Session restoration and Do Not Track enabled by default
- New profiles use aggressive Memory Saver with speculative preloading disabled
- No idle spare renderer or background browser residency
- Kwiken product branding, iconography, and lime/olive color system
- Windows registration for HTTP, HTTPS, HTML, and PDF defaults
- Clean migration from the earlier Electron prototype

## Google Sign-In

Google website sign-in opens in a normal top-level Chromium browser context.
The packaged build loads the Google Accounts sign-in page without Electron's
"browser or app may not be secure" block. Browser-level Chrome Sync is separate
and remains unavailable because Google does not issue private Chrome API
credentials for independent Chromium distributions.

## Extensions

Ungoogled Chromium intentionally cannot install directly from the Chrome Web
Store interface. Kwiken bundles the open-source Chromium Web Store compatibility
extension recommended by the ungoogled-chromium project and enables its CRX
installation mode. It works with the Chrome Web Store, Microsoft Edge Add-ons,
and Opera Add-ons. The bridge uses extension-management and download permissions
to install and update other extensions; its source is available at
[`NeverDecaf/chromium-web-store`](https://github.com/NeverDecaf/chromium-web-store).
Launch with `--disable-kwiken-web-store` to opt out.

## Lightweight Defaults

Kwiken keeps Chromium's sandbox, site isolation, GPU acceleration, extensions,
media support, and DevTools intact. To reduce memory without removing browser
capabilities, it does not keep a spare renderer waiting for the next
navigation. New profiles enable Chromium's aggressive Memory Saver, disable
speculative page preloading, and exit instead of keeping extension apps
resident after the last window closes. Existing profile choices are preserved.

Memory Saver and preloading remain user-configurable under
`chrome://settings/performance`. Launch with
`--enable-kwiken-spare-renderer` to restore Chromium's navigation prewarming.

## Reproducibility

The installable distribution uses the matching
`ungoogled-chromium-windows` GitHub Actions build of Chromium
`150.0.7871.186`. Its archive SHA-256 is pinned and verified before packaging.
Kwiken then compiles its native Win32 launcher, rebrands Chromium resource
packs and window icon, installs the pinned extension-store bridge, applies
first-run preferences, and creates the NSIS installer.

```powershell
.\chromium-fork\scripts\build-distribution.ps1
```

This fast build requires Python 3, the Visual Studio C++ build tools, and NSIS.
It downloads and checksum-verifies the pinned Chromium runtime automatically;
it does not require a Chromium source checkout.

The full source-fork path is also pinned and reproducible:

```powershell
.\chromium-fork\scripts\bootstrap.ps1
.\chromium-fork\scripts\build.ps1 -Jobs 2
```

When `chromium-fork/VERSION` changes on `master`, GitHub Actions builds the
Windows installer and publishes or refreshes the matching GitHub release.

See [`chromium-fork/README.md`](chromium-fork/README.md) for implementation,
authentication, codec, and build details.
