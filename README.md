<p align="center">
  <img src="chromium-fork/assets/kwiken-icon.png" alt="Kwiken" width="128">
</p>

<h1 align="center">Kwiken</h1>

<p align="center">
  A calm, lightweight Windows browser with native vertical tabs, built on the
  complete Chromium browser engine rather than Electron or an embedded webview.
</p>

![Kwiken browser with native vertical tabs](chromium-fork/assets/kwiken-browser.png)

## Install status

The [latest GitHub release](https://github.com/Mschmitt478/kwiken/releases/latest)
provides a public Windows installer, SHA-256 checksums, and verification
metadata. The installer is explicitly unsigned, so Windows reports an unknown
publisher until an environment-approved Authenticode signing and attestation
path is configured.

Kwiken installs per-user, creates Start menu and desktop shortcuts, registers
itself with Windows Default Apps, and keeps its profile in
`%LOCALAPPDATA%\Kwiken\User Data`.

## Browser Features

- Complete Chromium multi-process architecture and sandbox
- Native vertical tabs enabled on first launch
- Local profiles, history, bookmarks, passwords, passkeys, downloads, and DevTools
- Chromium extension support and normal website permissions
- Chrome, Edge, and Opera extension-store installation through a bundled open-source bridge
- Session restoration and Do Not Track enabled by default
- New profiles use aggressive Memory Saver with speculative preloading disabled
- No idle spare renderer or background browser residency
- Theme-aware Zen rail that defaults to Kwiken olive/lime and follows the
  selected Chromium, device, grayscale, or extension theme
- Rounded, profile-persistent Essentials grid with explicit load/unload actions
- Persistent folder groups with per-tab and group-wide load/unload actions
- Windows registration for HTTP, HTTPS, HTML, and PDF defaults
- Clean migration from the earlier Electron prototype

## Themes

New profiles start with Kwiken's logo-matching olive (`#B7D455`) in Chromium's
Neutral color variant. Use **Customize Chrome** on the New Tab page—or install
any normal Chromium theme—to change it. The vertical rail, Essential tiles,
active outline, toolbar, groups, and page surfaces follow that selection
automatically.

## Essentials and folders

On a regular profile, right-click any tab and choose **Add to Essentials** to
place it in the rounded favicon grid at the top of the rail. Essentials keep
their identity and order across browser restarts. Right-click an Essential and
choose **Remove from Essentials** to return it to the normal tab list.

Right-click a background Essential or a tab inside a folder to choose **Unload
tab**. Its tile, URL, title, favicon, Essential/folder identity, and position
remain in place without keeping the page loaded. Choose **Load tab** to restore
it. Right-click a folder header for **Load all tabs** and **Unload all tabs**.
The active tab and tabs using audio, capture, unsaved form state, DevTools, or
other protected browser state intentionally stay loaded; switch to another tab
before unloading the active one.

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

Kwiken builds its browser runtime from the repository's exact pinned Chromium
and depot_tools revisions. The native export binds the clean Kwiken commit,
complete Chromium dependency state, source delta, toolchain, build outputs, and
every runtime file into an authenticated READY/provenance handoff. The public
distribution bridge accepts only that handoff; it neither downloads a generic
Chromium build nor rewrites browser binaries after verification.

```powershell
.\chromium-fork\scripts\bootstrap.ps1
.\chromium-fork\scripts\build.ps1 -Jobs 2
.\chromium-fork\scripts\export-runtime.ps1 -Jobs 2
```

The manual GitHub Actions workflow runs only on an explicitly labeled,
controlled Windows builder. It produces a short-lived unsigned candidate plus
provenance with read-only repository permissions and has no tag/release path.
Public release automation remains disabled until the separate signing and
attestation environment is configured.

See [`chromium-fork/README.md`](chromium-fork/README.md) for implementation,
authentication, codec, and build details.
