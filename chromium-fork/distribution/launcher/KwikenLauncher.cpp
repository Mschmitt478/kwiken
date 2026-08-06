#include <windows.h>
#include <propkey.h>
#include <propsys.h>
#include <propvarutil.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <filesystem>
#include <fstream>
#include <string>
#include <string_view>
#include <vector>

namespace {

constexpr wchar_t kFeatureSwitch[] =
    L"--enable-features=VerticalTabs,VerticalTabsLaunch,"
    L"VerticalTabsExpandOnHover";
constexpr wchar_t kExtensionMimeSwitch[] =
    L"--extension-mime-request-handling=always-prompt-for-install";
constexpr wchar_t kDisableWebStoreSwitch[] =
    L"--disable-kwiken-web-store";
constexpr wchar_t kEnableSpareRendererSwitch[] =
    L"--enable-kwiken-spare-renderer";
constexpr wchar_t kDisableFeaturesSwitchPrefix[] = L"--disable-features=";
constexpr wchar_t kSpareRendererFeature[] =
    L"SpareRendererForSitePerProcess";
constexpr wchar_t kUserDataDirectorySwitch[] = L"--user-data-dir";
constexpr wchar_t kUserDataDirectorySwitchPrefix[] = L"--user-data-dir=";
constexpr wchar_t kBrowserModelSuffixSwitch[] =
    L"--register-chrome-browser-suffix=.Kwiken";
constexpr wchar_t kBrowserModelSuffixPrefix[] =
    L"--register-chrome-browser-suffix";
constexpr wchar_t kRepairShortcutsSwitch[] = L"--repair-shortcuts";
constexpr wchar_t kTaskbarAppId[] = L"Chromium.Kwiken.UserData.Default";

using Microsoft::WRL::ComPtr;

class ScopedComInitializer {
 public:
  ScopedComInitializer()
      : result_(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)) {}

  ~ScopedComInitializer() {
    if (SUCCEEDED(result_)) {
      CoUninitialize();
    }
  }

  bool available() const {
    return SUCCEEDED(result_) || result_ == RPC_E_CHANGED_MODE;
  }

 private:
  HRESULT result_;
};

std::filesystem::path GetKnownFolder(REFKNOWNFOLDERID folder_id) {
  PWSTR folder_path = nullptr;
  if (FAILED(SHGetKnownFolderPath(folder_id, KF_FLAG_CREATE, nullptr,
                                  &folder_path))) {
    return {};
  }
  std::filesystem::path result(folder_path);
  CoTaskMemFree(folder_path);
  return result;
}

std::filesystem::path GetExecutableDirectory() {
  std::wstring buffer(32768, L'\0');
  const DWORD length =
      GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
  if (length == 0 || length == buffer.size()) {
    return {};
  }
  buffer.resize(length);
  return std::filesystem::path(buffer).parent_path();
}

std::filesystem::path GetDefaultUserDataDirectory() {
  const std::filesystem::path local_app_data =
      GetKnownFolder(FOLDERID_LocalAppData);
  if (local_app_data.empty()) {
    return {};
  }
  return local_app_data / L"Kwiken" / L"User Data";
}

bool StartsWith(std::wstring_view value, std::wstring_view prefix) {
  return value.size() >= prefix.size() &&
         value.substr(0, prefix.size()) == prefix;
}

void AddDisabledFeature(std::vector<std::wstring>* arguments,
                        std::wstring_view feature) {
  for (std::wstring& argument : *arguments) {
    if (!StartsWith(argument, kDisableFeaturesSwitchPrefix)) {
      continue;
    }
    if (argument.find(feature) == std::wstring::npos) {
      if (argument.size() >
          std::wstring_view(kDisableFeaturesSwitchPrefix).size()) {
        argument.push_back(L',');
      }
      argument.append(feature);
    }
    return;
  }
  arguments->insert(arguments->begin(),
                    std::wstring(kDisableFeaturesSwitchPrefix) +
                        std::wstring(feature));
}

std::wstring QuoteArgument(std::wstring_view argument) {
  if (argument.empty()) {
    return L"\"\"";
  }
  if (argument.find_first_of(L" \t\n\v\"") == std::wstring_view::npos) {
    return std::wstring(argument);
  }

  std::wstring quoted = L"\"";
  size_t backslashes = 0;
  for (const wchar_t character : argument) {
    if (character == L'\\') {
      ++backslashes;
      continue;
    }
    if (character == L'\"') {
      quoted.append(backslashes * 2 + 1, L'\\');
      quoted.push_back(character);
      backslashes = 0;
      continue;
    }
    quoted.append(backslashes, L'\\');
    backslashes = 0;
    quoted.push_back(character);
  }
  quoted.append(backslashes * 2, L'\\');
  quoted.push_back(L'\"');
  return quoted;
}

std::filesystem::path NormalizePath(const std::filesystem::path& path) {
  std::wstring buffer(32768, L'\0');
  const DWORD length = GetFullPathNameW(
      path.c_str(), static_cast<DWORD>(buffer.size()), buffer.data(), nullptr);
  if (length == 0 || length >= buffer.size()) {
    return path.lexically_normal();
  }
  buffer.resize(length);
  return std::filesystem::path(buffer).lexically_normal();
}

bool PathsEqual(const std::filesystem::path& left,
                const std::filesystem::path& right) {
  const std::wstring normalized_left = NormalizePath(left).wstring();
  const std::wstring normalized_right = NormalizePath(right).wstring();
  return CompareStringOrdinal(normalized_left.c_str(), -1,
                              normalized_right.c_str(), -1, TRUE) == CSTR_EQUAL;
}

bool SetStringProperty(IPropertyStore* property_store,
                       const PROPERTYKEY& key,
                       const std::wstring& value) {
  PROPVARIANT property_value;
  PropVariantInit(&property_value);
  const HRESULT initialize_result =
      InitPropVariantFromString(value.c_str(), &property_value);
  if (FAILED(initialize_result)) {
    return false;
  }
  const HRESULT set_result = property_store->SetValue(key, property_value);
  PropVariantClear(&property_value);
  return SUCCEEDED(set_result);
}

bool GetStringProperty(IPropertyStore* property_store,
                       const PROPERTYKEY& key,
                       std::wstring* value) {
  PROPVARIANT property_value;
  PropVariantInit(&property_value);
  const HRESULT result = property_store->GetValue(key, &property_value);
  if (FAILED(result) || property_value.vt != VT_LPWSTR ||
      !property_value.pwszVal) {
    PropVariantClear(&property_value);
    return false;
  }
  value->assign(property_value.pwszVal);
  PropVariantClear(&property_value);
  return true;
}

bool RepairShortcut(const std::filesystem::path& shortcut_path,
                    const std::filesystem::path& launcher_path,
                    const std::filesystem::path& browser_path) {
  ComPtr<IShellLinkW> shell_link;
  if (FAILED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(shell_link.GetAddressOf())))) {
    return false;
  }

  ComPtr<IPersistFile> persist_file;
  if (FAILED(shell_link.As(&persist_file)) ||
      FAILED(persist_file->Load(shortcut_path.c_str(), STGM_READWRITE))) {
    return false;
  }

  std::wstring target_buffer(32768, L'\0');
  WIN32_FIND_DATAW target_data{};
  if (FAILED(shell_link->GetPath(target_buffer.data(),
                                 static_cast<int>(target_buffer.size()),
                                 &target_data, SLGP_RAWPATH))) {
    return false;
  }
  target_buffer.resize(wcslen(target_buffer.c_str()));
  const std::filesystem::path target_path(target_buffer);
  if (!PathsEqual(target_path, launcher_path) &&
      !PathsEqual(target_path, browser_path)) {
    return false;
  }

  ComPtr<IPropertyStore> property_store;
  if (FAILED(shell_link.As(&property_store))) {
    return false;
  }
  std::wstring current_app_id;
  std::wstring icon_buffer(32768, L'\0');
  int icon_index = -1;
  const bool has_icon =
      SUCCEEDED(shell_link->GetIconLocation(
          icon_buffer.data(), static_cast<int>(icon_buffer.size()),
          &icon_index));
  icon_buffer.resize(wcslen(icon_buffer.c_str()));
  if (PathsEqual(target_path, launcher_path) &&
      GetStringProperty(property_store.Get(), PKEY_AppUserModel_ID,
                        &current_app_id) &&
      current_app_id == kTaskbarAppId && has_icon && icon_index == 0 &&
      PathsEqual(icon_buffer, launcher_path)) {
    return false;
  }

  if (FAILED(shell_link->SetPath(launcher_path.c_str())) ||
      FAILED(shell_link->SetWorkingDirectory(
          launcher_path.parent_path().c_str())) ||
      FAILED(shell_link->SetIconLocation(launcher_path.c_str(), 0)) ||
      FAILED(shell_link->SetDescription(L"Kwiken Browser"))) {
    return false;
  }

  if (!SetStringProperty(property_store.Get(), PKEY_AppUserModel_ID,
                         kTaskbarAppId) ||
      FAILED(property_store->Commit()) ||
      FAILED(persist_file->Save(shortcut_path.c_str(), TRUE))) {
    return false;
  }

  SHChangeNotify(SHCNE_UPDATEITEM, SHCNF_PATHW, shortcut_path.c_str(), nullptr);
  return true;
}

void RepairShortcuts(const std::filesystem::path& executable_directory,
                     const std::filesystem::path& browser_path) {
  const std::filesystem::path launcher_path =
      executable_directory / L"Kwiken.exe";
  const std::filesystem::path programs = GetKnownFolder(FOLDERID_Programs);
  const std::filesystem::path desktop = GetKnownFolder(FOLDERID_Desktop);

  bool shortcuts_changed = false;
  if (!programs.empty()) {
    shortcuts_changed =
        RepairShortcut(programs / L"Kwiken" / L"Kwiken.lnk", launcher_path,
                       browser_path) ||
        shortcuts_changed;
  }
  if (!desktop.empty()) {
    shortcuts_changed = RepairShortcut(desktop / L"Kwiken.lnk", launcher_path,
                                       browser_path) ||
                        shortcuts_changed;
  }

  const std::filesystem::path roaming_app_data =
      GetKnownFolder(FOLDERID_RoamingAppData);
  if (roaming_app_data.empty()) {
    return;
  }
  const std::filesystem::path taskbar_shortcuts =
      roaming_app_data / L"Microsoft" / L"Internet Explorer" /
      L"Quick Launch" / L"User Pinned" / L"TaskBar";
  std::error_code error;
  for (std::filesystem::directory_iterator iterator(taskbar_shortcuts, error),
       end;
       !error && iterator != end; iterator.increment(error)) {
    if (!iterator->is_regular_file(error) ||
        CompareStringOrdinal(iterator->path().extension().c_str(), -1, L".lnk",
                             -1, TRUE) != CSTR_EQUAL) {
      continue;
    }
    shortcuts_changed =
        RepairShortcut(iterator->path(), launcher_path, browser_path) ||
        shortcuts_changed;
  }

  if (shortcuts_changed) {
    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
  }
}

bool GetProcessPath(DWORD process_id, std::filesystem::path* process_path) {
  const HANDLE process =
      OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
  if (!process) {
    return false;
  }
  std::wstring path_buffer(32768, L'\0');
  DWORD path_length = static_cast<DWORD>(path_buffer.size());
  const BOOL success = QueryFullProcessImageNameW(
      process, 0, path_buffer.data(), &path_length);
  CloseHandle(process);
  if (!success) {
    return false;
  }
  path_buffer.resize(path_length);
  *process_path = std::filesystem::path(path_buffer);
  return true;
}

struct WindowRepairContext {
  const std::filesystem::path& browser_path;
  const std::filesystem::path& launcher_path;
  bool repaired = false;
};

BOOL CALLBACK RepairBrowserWindow(HWND window, LPARAM parameter) {
  if (!IsWindowVisible(window)) {
    return TRUE;
  }

  DWORD process_id = 0;
  GetWindowThreadProcessId(window, &process_id);
  std::filesystem::path process_path;
  if (process_id == 0 || !GetProcessPath(process_id, &process_path)) {
    return TRUE;
  }

  auto* context = reinterpret_cast<WindowRepairContext*>(parameter);
  if (!PathsEqual(process_path, context->browser_path)) {
    return TRUE;
  }

  ComPtr<IPropertyStore> property_store;
  if (FAILED(SHGetPropertyStoreForWindow(
          window, IID_PPV_ARGS(property_store.GetAddressOf())))) {
    return TRUE;
  }
  std::wstring current_app_id;
  if (!GetStringProperty(property_store.Get(), PKEY_AppUserModel_ID,
                         &current_app_id) ||
      current_app_id != kTaskbarAppId) {
    return TRUE;
  }

  const std::wstring relaunch_command =
      QuoteArgument(context->launcher_path.wstring());
  const std::wstring relaunch_icon =
      context->launcher_path.wstring() + L",0";
  if (SetStringProperty(property_store.Get(), PKEY_AppUserModel_ID,
                        kTaskbarAppId) &&
      SetStringProperty(property_store.Get(),
                        PKEY_AppUserModel_RelaunchCommand,
                        relaunch_command) &&
      SetStringProperty(property_store.Get(),
                        PKEY_AppUserModel_RelaunchIconResource,
                        relaunch_icon) &&
      SetStringProperty(property_store.Get(),
                        PKEY_AppUserModel_RelaunchDisplayNameResource,
                        L"Kwiken") &&
      SUCCEEDED(property_store->Commit())) {
    context->repaired = true;
  }
  return TRUE;
}

bool RepairBrowserWindows(const std::filesystem::path& browser_path,
                          const std::filesystem::path& launcher_path) {
  WindowRepairContext context{browser_path, launcher_path};
  EnumWindows(RepairBrowserWindow, reinterpret_cast<LPARAM>(&context));
  return context.repaired;
}

void SeedProfile(const std::filesystem::path& user_data_directory) {
  const std::filesystem::path preferences =
      user_data_directory / L"Default" / L"Preferences";
  std::error_code error;
  if (std::filesystem::exists(preferences, error)) {
    return;
  }
  std::filesystem::create_directories(preferences.parent_path(), error);
  if (error) {
    return;
  }

  // Chromium derives the complete first-profile palette from this
  // logo-matching olive seed. Later theme choices remain entirely user-owned.
  constexpr char kInitialPreferences[] = R"json({
  "bookmark_bar": {
    "show_on_all_tabs": false
  },
  "browser": {
    "check_default_browser": true,
    "show_home_button": false,
    "theme": {
      "color_scheme2": 1,
      "color_variant2": 2,
      "user_color2": -4729771
    }
  },
  "credentials_enable_autosignin": true,
  "credentials_enable_service": true,
  "enable_do_not_track": true,
  "extensions": {
    "theme": {
      "id": "user_color_theme_id"
    }
  },
  "homepage": "https://duckduckgo.com/",
  "homepage_is_newtabpage": true,
  "net": {
    "network_prediction_options": 2
  },
  "profile": {
    "exit_type": "Normal",
    "exited_cleanly": true,
    "name": "Kwiken"
  },
  "session": {
    "restore_on_startup": 1
  },
  "signin": {
    "allowed": false
  },
  "vertical_tabs": {
    "collapsed_state": false,
    "enabled": true,
    "enabled_first_time": true,
    "expand_on_hover": false,
    "uncollapsed_width": 260
  }
})json";

  std::ofstream output(preferences, std::ios::binary | std::ios::trunc);
  output.write(kInitialPreferences, sizeof(kInitialPreferences) - 1);
}

void SeedLocalState(const std::filesystem::path& user_data_directory) {
  const std::filesystem::path local_state =
      user_data_directory / L"Local State";
  std::error_code error;
  if (std::filesystem::exists(local_state, error)) {
    return;
  }
  std::filesystem::create_directories(user_data_directory, error);
  if (error) {
    return;
  }

  constexpr char kInitialLocalState[] = R"json({
  "background_mode": {
    "enabled": false
  },
  "performance_tuning": {
    "high_efficiency_mode": {
      "aggressiveness": 2,
      "state": 2
    }
  }
})json";

  std::ofstream output(local_state, std::ios::binary | std::ios::trunc);
  output.write(kInitialLocalState, sizeof(kInitialLocalState) - 1);
}

int ShowLaunchError(const std::wstring& message) {
  MessageBoxW(nullptr, message.c_str(), L"Kwiken", MB_OK | MB_ICONERROR);
  return 1;
}

}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  ScopedComInitializer com_initializer;
  const std::filesystem::path executable_directory = GetExecutableDirectory();
  const std::filesystem::path browser_path =
      executable_directory / L"runtime" / L"chrome.exe";
  if (executable_directory.empty() || !std::filesystem::exists(browser_path)) {
    return ShowLaunchError(
        L"Kwiken's Chromium runtime is missing. Reinstall Kwiken to repair it.");
  }

  int argument_count = 0;
  LPWSTR* raw_arguments =
      CommandLineToArgvW(GetCommandLineW(), &argument_count);
  if (!raw_arguments) {
    return ShowLaunchError(L"Kwiken could not read its launch arguments.");
  }

  std::vector<std::wstring> arguments;
  arguments.reserve(static_cast<size_t>(argument_count) + 6);
  bool has_user_data_directory = false;
  bool disables_vertical_tabs = false;
  bool disables_extensions = false;
  bool disables_web_store = false;
  bool enables_spare_renderer = false;
  bool has_extension_mime_switch = false;
  bool repair_shortcuts_only = false;
  std::filesystem::path requested_user_data_directory;
  for (int index = 1; index < argument_count; ++index) {
    std::wstring argument = raw_arguments[index];
    if (argument == kRepairShortcutsSwitch) {
      repair_shortcuts_only = true;
      continue;
    }
    if (argument == kDisableWebStoreSwitch) {
      disables_web_store = true;
      continue;
    }
    if (argument == kEnableSpareRendererSwitch) {
      enables_spare_renderer = true;
      continue;
    }
    if (argument == kBrowserModelSuffixPrefix ||
        StartsWith(argument,
                   std::wstring(kBrowserModelSuffixPrefix) + L"=")) {
      continue;
    }
    if (argument == kUserDataDirectorySwitch ||
        StartsWith(argument, kUserDataDirectorySwitchPrefix)) {
      has_user_data_directory = true;
      if (argument == kUserDataDirectorySwitch && index + 1 < argument_count) {
        requested_user_data_directory = raw_arguments[index + 1];
      } else if (StartsWith(argument, kUserDataDirectorySwitchPrefix)) {
        requested_user_data_directory = argument.substr(
            std::wstring_view(kUserDataDirectorySwitchPrefix).size());
      }
    }
    if (StartsWith(argument, kDisableFeaturesSwitchPrefix) &&
        argument.find(L"VerticalTabs") != std::wstring::npos) {
      disables_vertical_tabs = true;
    }
    if (argument == L"--disable-extensions") {
      disables_extensions = true;
    }
    if (StartsWith(argument, L"--extension-mime-request-handling=")) {
      has_extension_mime_switch = true;
    }
    arguments.push_back(std::move(argument));
  }
  LocalFree(raw_arguments);

  if (com_initializer.available()) {
    RepairShortcuts(executable_directory, browser_path);
  }
  if (repair_shortcuts_only) {
    return 0;
  }

  std::filesystem::path user_data_directory = requested_user_data_directory;
  if (!has_user_data_directory) {
    user_data_directory = GetDefaultUserDataDirectory();
    if (user_data_directory.empty()) {
      return ShowLaunchError(L"Kwiken could not locate your local app data.");
    }
    arguments.insert(arguments.begin(),
                     L"--user-data-dir=" + user_data_directory.wstring());
  }
  if (!user_data_directory.empty()) {
    if (user_data_directory.is_relative()) {
      user_data_directory = browser_path.parent_path() / user_data_directory;
    }
    SeedLocalState(user_data_directory);
    SeedProfile(user_data_directory);
  }
  if (!disables_vertical_tabs) {
    arguments.insert(arguments.begin(), kFeatureSwitch);
  }
  if (!enables_spare_renderer) {
    AddDisabledFeature(&arguments, kSpareRendererFeature);
  }
  const std::filesystem::path web_store_extension =
      executable_directory / L"extensions" / L"chromium-web-store";
  std::error_code extension_error;
  if (!disables_extensions && !disables_web_store &&
      std::filesystem::exists(web_store_extension / L"manifest.json",
                              extension_error)) {
    bool merged_with_existing_switch = false;
    for (std::wstring& argument : arguments) {
      if (StartsWith(argument, L"--load-extension=")) {
        argument.push_back(L',');
        argument.append(web_store_extension.wstring());
        merged_with_existing_switch = true;
        break;
      }
    }
    if (!merged_with_existing_switch) {
      arguments.insert(arguments.begin(),
                       L"--load-extension=" + web_store_extension.wstring());
    }
    if (!has_extension_mime_switch) {
      arguments.insert(arguments.begin(), kExtensionMimeSwitch);
    }
  }
  arguments.insert(arguments.begin(), kBrowserModelSuffixSwitch);
  arguments.insert(arguments.begin(), L"--no-first-run");

  std::wstring command_line = QuoteArgument(browser_path.wstring());
  for (const std::wstring& argument : arguments) {
    command_line.push_back(L' ');
    command_line.append(QuoteArgument(argument));
  }

  STARTUPINFOW startup_info{};
  startup_info.cb = sizeof(startup_info);
  PROCESS_INFORMATION process_info{};
  std::vector<wchar_t> mutable_command(command_line.begin(), command_line.end());
  mutable_command.push_back(L'\0');

  if (!CreateProcessW(browser_path.c_str(), mutable_command.data(), nullptr,
                      nullptr, FALSE, 0, nullptr,
                      browser_path.parent_path().c_str(), &startup_info,
                      &process_info)) {
    const DWORD error = GetLastError();
    return ShowLaunchError(L"Kwiken could not start its Chromium runtime.\n\n"
                           L"Windows error: " +
                           std::to_wstring(error));
  }

  CloseHandle(process_info.hThread);
  CloseHandle(process_info.hProcess);

  if (com_initializer.available()) {
    const std::filesystem::path launcher_path =
        executable_directory / L"Kwiken.exe";
    int repaired_passes = 0;
    for (int attempt = 0; attempt < 40 && repaired_passes < 12; ++attempt) {
      if (RepairBrowserWindows(browser_path, launcher_path)) {
        ++repaired_passes;
      }
      Sleep(250);
    }
  }
  return 0;
}
