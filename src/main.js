const { app, BrowserWindow, WebContentsView, ipcMain } = require("electron");
const path = require("path");

const SIDEBAR_WIDTH = 248;
const TOPBAR_HEIGHT = 76;
const HOME_URL = "https://www.google.com";
const isSmokeTest = process.argv.includes("--smoke-test");

let mainWindow;
let activeTabId = null;
let nextTabId = 1;
const tabs = new Map();

function tabSnapshot(tab) {
  const history = tab.view.webContents.navigationHistory;
  return {
    id: tab.id,
    title: tab.title || "New Tab",
    url: tab.url,
    loading: tab.loading,
    canGoBack: history.canGoBack(),
    canGoForward: history.canGoForward()
  };
}

function publishState() {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  mainWindow.webContents.send("browser:state", {
    activeTabId,
    tabs: [...tabs.values()].map(tabSnapshot)
  });
}

function layoutActiveTab() {
  if (!mainWindow || activeTabId === null) return;
  const tab = tabs.get(activeTabId);
  if (!tab) return;
  const [width, height] = mainWindow.getContentSize();
  tab.view.setBounds({
    x: SIDEBAR_WIDTH,
    y: TOPBAR_HEIGHT,
    width: Math.max(0, width - SIDEBAR_WIDTH),
    height: Math.max(0, height - TOPBAR_HEIGHT)
  });
}

function normalizeAddress(input) {
  const value = String(input || "").trim();
  if (!value) return HOME_URL;

  try {
    const parsed = new URL(value);
    if (["http:", "https:"].includes(parsed.protocol)) return parsed.href;
  } catch {}

  if (/^(localhost|127\.0\.0\.1)(:\d+)?(\/.*)?$/i.test(value)) {
    return `http://${value}`;
  }

  if (/^[\w.-]+\.[a-z]{2,}([/:?#].*)?$/i.test(value)) {
    return `https://${value}`;
  }

  return `https://www.google.com/search?q=${encodeURIComponent(value)}`;
}

function attachView(tab) {
  if (activeTabId !== null) {
    const current = tabs.get(activeTabId);
    if (current) mainWindow.contentView.removeChildView(current.view);
  }
  activeTabId = tab.id;
  mainWindow.contentView.addChildView(tab.view);
  layoutActiveTab();
  tab.view.webContents.focus();
  publishState();
}

function createTab(address = HOME_URL, activate = true) {
  const id = nextTabId++;
  const view = new WebContentsView({
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });
  view.setBackgroundColor("#f7f7f5");

  const tab = {
    id,
    view,
    title: "New Tab",
    url: normalizeAddress(address),
    loading: true
  };
  tabs.set(id, tab);

  const update = () => {
    tab.url = view.webContents.getURL() || tab.url;
    tab.title = view.webContents.getTitle() || "New Tab";
    publishState();
  };

  view.webContents.on("did-start-loading", () => {
    tab.loading = true;
    update();
  });
  view.webContents.on("did-stop-loading", () => {
    tab.loading = false;
    update();
  });
  view.webContents.on("page-title-updated", (_event, title) => {
    tab.title = title;
    publishState();
  });
  view.webContents.on("did-navigate", update);
  view.webContents.on("did-navigate-in-page", update);
  view.webContents.setWindowOpenHandler(({ url }) => {
    createTab(url, true);
    return { action: "deny" };
  });
  view.webContents.on("will-navigate", (event, url) => {
    if (!/^https?:/i.test(url)) event.preventDefault();
  });
  view.webContents.on("before-input-event", (event, input) => {
    const modifier = input.control || input.meta;
    if (!modifier || input.type !== "keyDown") return;
    const key = input.key.toLowerCase();
    if (key === "l") {
      event.preventDefault();
      mainWindow.webContents.send("browser:focus-address");
    } else if (key === "t") {
      event.preventDefault();
      createTab(HOME_URL, true);
    } else if (key === "w") {
      event.preventDefault();
      closeTab(activeTabId);
    } else if (key === "r") {
      event.preventDefault();
      view.webContents.reload();
    }
  });

  if (activate) attachView(tab);
  view.webContents.loadURL(tab.url);
  return tab;
}

function activateTab(id) {
  const tab = tabs.get(Number(id));
  if (tab && tab.id !== activeTabId) attachView(tab);
}

function closeTab(id) {
  const numericId = Number(id);
  const tab = tabs.get(numericId);
  if (!tab) return;

  const ids = [...tabs.keys()];
  const closedIndex = ids.indexOf(numericId);
  if (numericId === activeTabId) {
    mainWindow.contentView.removeChildView(tab.view);
    activeTabId = null;
  }
  tabs.delete(numericId);
  tab.view.webContents.close();

  if (tabs.size === 0) {
    createTab(HOME_URL, true);
  } else if (activeTabId === null) {
    const nextId = ids[closedIndex + 1] || ids[closedIndex - 1];
    attachView(tabs.get(nextId));
  } else {
    publishState();
  }
}

function activeContents() {
  return tabs.get(activeTabId)?.view.webContents;
}

function registerIpc() {
  ipcMain.handle("browser:get-state", () => ({
    activeTabId,
    tabs: [...tabs.values()].map(tabSnapshot)
  }));
  ipcMain.on("browser:navigate", (_event, address) => {
    activeContents()?.loadURL(normalizeAddress(address));
  });
  ipcMain.on("browser:new-tab", () => createTab(HOME_URL, true));
  ipcMain.on("browser:activate-tab", (_event, id) => activateTab(id));
  ipcMain.on("browser:close-tab", (_event, id) => closeTab(id));
  ipcMain.on("browser:back", () => {
    const contents = activeContents();
    if (contents?.navigationHistory.canGoBack()) contents.navigationHistory.goBack();
  });
  ipcMain.on("browser:forward", () => {
    const contents = activeContents();
    if (contents?.navigationHistory.canGoForward()) contents.navigationHistory.goForward();
  });
  ipcMain.on("browser:reload", () => {
    const contents = activeContents();
    if (!contents) return;
    contents.isLoading() ? contents.stop() : contents.reload();
  });
  ipcMain.on("browser:home", () => activeContents()?.loadURL(HOME_URL));
  ipcMain.on("window:minimize", () => mainWindow?.minimize());
  ipcMain.on("window:maximize", () => {
    if (!mainWindow) return;
    mainWindow.isMaximized() ? mainWindow.unmaximize() : mainWindow.maximize();
  });
  ipcMain.on("window:close", () => mainWindow?.close());
}

function runSmokeTest(tab) {
  const timeout = setTimeout(() => {
    console.error("KWIKEN_SMOKE_FAILED timeout");
    app.exit(1);
  }, 30000);

  tab.view.webContents.once("did-finish-load", () => {
    clearTimeout(timeout);
    const url = tab.view.webContents.getURL();
    const title = tab.view.webContents.getTitle();
    if (/^https:\/\/(www\.)?google\./i.test(url) && title) {
      console.log(`KWIKEN_SMOKE_OK ${url} ${title}`);
      app.exit(0);
    } else {
      console.error(`KWIKEN_SMOKE_FAILED ${url} ${title}`);
      app.exit(1);
    }
  });
  tab.view.webContents.once("did-fail-load", (_event, code, description, url) => {
    clearTimeout(timeout);
    console.error(`KWIKEN_SMOKE_FAILED ${code} ${description} ${url}`);
    app.exit(1);
  });
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1380,
    height: 880,
    minWidth: 860,
    minHeight: 580,
    frame: false,
    backgroundColor: "#11130f",
    show: !isSmokeTest,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });

  mainWindow.loadFile(path.join(__dirname, "renderer", "index.html"));
  mainWindow.on("resize", layoutActiveTab);
  mainWindow.on("maximize", () => mainWindow.webContents.send("window:maximized", true));
  mainWindow.on("unmaximize", () => mainWindow.webContents.send("window:maximized", false));
  mainWindow.on("closed", () => {
    mainWindow = null;
  });
  mainWindow.webContents.once("did-finish-load", () => {
    const tab = createTab(HOME_URL, true);
    if (isSmokeTest) runSmokeTest(tab);
  });
}

app.whenReady().then(() => {
  app.setName("Kwiken");
  registerIpc();
  createWindow();
});

app.on("window-all-closed", () => app.quit());
