const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("kwiken", {
  getState: () => ipcRenderer.invoke("browser:get-state"),
  onState: (callback) => ipcRenderer.on("browser:state", (_event, state) => callback(state)),
  onFocusAddress: (callback) => ipcRenderer.on("browser:focus-address", callback),
  onMaximized: (callback) => ipcRenderer.on("window:maximized", (_event, value) => callback(value)),
  navigate: (address) => ipcRenderer.send("browser:navigate", address),
  newTab: () => ipcRenderer.send("browser:new-tab"),
  activateTab: (id) => ipcRenderer.send("browser:activate-tab", id),
  closeTab: (id) => ipcRenderer.send("browser:close-tab", id),
  back: () => ipcRenderer.send("browser:back"),
  forward: () => ipcRenderer.send("browser:forward"),
  reload: () => ipcRenderer.send("browser:reload"),
  home: () => ipcRenderer.send("browser:home"),
  minimize: () => ipcRenderer.send("window:minimize"),
  maximize: () => ipcRenderer.send("window:maximize"),
  closeWindow: () => ipcRenderer.send("window:close")
});
