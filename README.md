# Kwiken

Kwiken is an original desktop browser shell focused on calm, fast navigation. It uses Electron only as its embedded standards-compatible web rendering engine; the browser interface, sidebar tabs, navigation model, and application behavior are implemented specifically for Kwiken.

## Run

```powershell
npm install
npm start
```

## Smoke test

```powershell
npm run smoke
```

The smoke test launches a hidden Kwiken window, loads Google, validates the resulting URL and title, then exits.

## Shortcuts

- `Ctrl+L` focuses the address bar.
- `Ctrl+T` opens a new tab.
- `Ctrl+W` closes the active tab.
- `Ctrl+R` reloads the active page.
