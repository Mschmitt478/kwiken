#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>

#include <filesystem>
#include <fstream>
#include <string>
#include <string_view>
#include <vector>

namespace {

constexpr wchar_t kFeatureSwitch[] =
    L"--enable-features=VerticalTabs,VerticalTabsLaunch,"
    L"VerticalTabsExpandOnHover";

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
  PWSTR local_app_data = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE,
                                  nullptr, &local_app_data))) {
    return {};
  }
  std::filesystem::path result =
      std::filesystem::path(local_app_data) / L"Kwiken" / L"User Data";
  CoTaskMemFree(local_app_data);
  return result;
}

bool StartsWith(std::wstring_view value, std::wstring_view prefix) {
  return value.size() >= prefix.size() &&
         value.substr(0, prefix.size()) == prefix;
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

int ShowLaunchError(const std::wstring& message) {
  MessageBoxW(nullptr, message.c_str(), L"Kwiken", MB_OK | MB_ICONERROR);
  return 1;
}

}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
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
  arguments.reserve(static_cast<size_t>(argument_count) + 3);
  bool has_user_data_directory = false;
  bool disables_vertical_tabs = false;
  for (int index = 1; index < argument_count; ++index) {
    std::wstring argument = raw_arguments[index];
    if (argument == L"--user-data-dir" ||
        StartsWith(argument, L"--user-data-dir=")) {
      has_user_data_directory = true;
    }
    if (StartsWith(argument, L"--disable-features=") &&
        argument.find(L"VerticalTabs") != std::wstring::npos) {
      disables_vertical_tabs = true;
    }
    arguments.push_back(std::move(argument));
  }
  LocalFree(raw_arguments);

  const std::filesystem::path user_data_directory =
      GetDefaultUserDataDirectory();
  if (!has_user_data_directory) {
    if (user_data_directory.empty()) {
      return ShowLaunchError(L"Kwiken could not locate your local app data.");
    }
    SeedProfile(user_data_directory);
    arguments.insert(arguments.begin(),
                     L"--user-data-dir=" + user_data_directory.wstring());
  }
  if (!disables_vertical_tabs) {
    arguments.insert(arguments.begin(), kFeatureSwitch);
  }
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
  return 0;
}
