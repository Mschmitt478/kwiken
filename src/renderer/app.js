const tabsElement = document.querySelector("#tabs");
const addressInput = document.querySelector("#address");
const backButton = document.querySelector("#back");
const forwardButton = document.querySelector("#forward");
const reloadButton = document.querySelector("#reload");

let browserState = { activeTabId: null, tabs: [] };

function activeTab() {
  return browserState.tabs.find((tab) => tab.id === browserState.activeTabId);
}

function renderTabs() {
  tabsElement.replaceChildren();

  for (const tab of browserState.tabs) {
    const tabButton = document.createElement("button");
    tabButton.type = "button";
    tabButton.className = `tab${tab.id === browserState.activeTabId ? " active" : ""}${tab.loading ? " loading" : ""}`;
    tabButton.title = tab.title;
    tabButton.addEventListener("click", () => window.kwiken.activateTab(tab.id));

    const icon = document.createElement("span");
    icon.className = "tab-icon";
    icon.textContent = tab.loading ? "·" : (tab.title?.[0] || "K").toUpperCase();

    const title = document.createElement("span");
    title.className = "tab-title";
    title.textContent = tab.title || "New Tab";

    const close = document.createElement("button");
    close.type = "button";
    close.className = "tab-close";
    close.title = "Close tab";
    close.textContent = "×";
    close.addEventListener("click", (event) => {
      event.stopPropagation();
      window.kwiken.closeTab(tab.id);
    });

    tabButton.append(icon, title, close);
    tabsElement.append(tabButton);
  }
}

function render(state) {
  browserState = state;
  const current = activeTab();
  renderTabs();
  if (document.activeElement !== addressInput) addressInput.value = current?.url || "";
  backButton.disabled = !current?.canGoBack;
  forwardButton.disabled = !current?.canGoForward;
  reloadButton.textContent = current?.loading ? "×" : "↻";
  reloadButton.title = current?.loading ? "Stop" : "Reload";
}

function focusAddress() {
  addressInput.focus();
  addressInput.select();
}

document.querySelector("#address-form").addEventListener("submit", (event) => {
  event.preventDefault();
  window.kwiken.navigate(addressInput.value);
  addressInput.blur();
});

document.querySelector("#new-tab").addEventListener("click", window.kwiken.newTab);
backButton.addEventListener("click", window.kwiken.back);
forwardButton.addEventListener("click", window.kwiken.forward);
reloadButton.addEventListener("click", window.kwiken.reload);
document.querySelector("#home").addEventListener("click", window.kwiken.home);
document.querySelector("#minimize").addEventListener("click", window.kwiken.minimize);
document.querySelector("#maximize").addEventListener("click", window.kwiken.maximize);
document.querySelector("#close-window").addEventListener("click", window.kwiken.closeWindow);

document.addEventListener("keydown", (event) => {
  if (!(event.ctrlKey || event.metaKey)) return;
  const key = event.key.toLowerCase();
  if (key === "l") {
    event.preventDefault();
    focusAddress();
  } else if (key === "t") {
    event.preventDefault();
    window.kwiken.newTab();
  } else if (key === "w") {
    event.preventDefault();
    if (browserState.activeTabId !== null) window.kwiken.closeTab(browserState.activeTabId);
  }
});

window.kwiken.onState(render);
window.kwiken.onFocusAddress(focusAddress);
window.kwiken.getState().then(render);
