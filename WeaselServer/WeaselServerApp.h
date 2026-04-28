#pragma once

#include "resource.h"
#include <resource.h>
#include <WeaselIPC.h>
#include <WeaselUI.h>
#include <RimeWithWeasel.h>
#include <WeaselUtility.h>
#include <filesystem>
#include <functional>
#include <memory>
#include <winsparkle.h>

#include "WeaselTrayIcon.h"
#include "DevConsole.h"
#include "ContextHistory.h"
#include "MemoryCompressor.h"

namespace fs = std::filesystem;
enum class AIAssistantStandaloneMode : int;

class WeaselServerApp {
 public:
  static bool execute(const fs::path& cmd, const std::wstring& args) {
    return (uintptr_t)ShellExecuteW(NULL, NULL, cmd.c_str(), args.c_str(), NULL,
                                    SW_SHOWNORMAL) > 32;
  }

  static bool explore(const fs::path& path) {
    std::wstring quoted_path(L"\"" + path.wstring() + L"\"");
    return (uintptr_t)ShellExecuteW(NULL, L"explore", quoted_path.c_str(), NULL,
                                    NULL, SW_SHOWNORMAL) > 32;
  }

  static bool open(const fs::path& path) {
    return (uintptr_t)ShellExecuteW(NULL, L"open", path.c_str(), NULL, NULL,
                                    SW_SHOWNORMAL) > 32;
  }
  static bool launch_self(const std::wstring& args) {
    WCHAR exe_path[MAX_PATH] = {0};
    GetModuleFileNameW(GetModuleHandle(NULL), exe_path, _countof(exe_path));
    return (uintptr_t)ShellExecuteW(NULL, NULL, exe_path, args.c_str(), NULL,
                                    SW_SHOWNORMAL) > 32;
  }
  static bool launch_binary(const fs::path& executable,
                            const std::wstring& args) {
    if (executable.empty()) {
      return false;
    }

    const std::wstring executable_path = executable.wstring();
    std::wstring command_line = L"\"" + executable_path + L"\"";
    if (!args.empty()) {
      command_line += L" ";
      command_line += args;
    }
    command_line.push_back(L'\0');

    STARTUPINFOW startup_info = {sizeof(startup_info)};
    startup_info.dwFlags = STARTF_USESHOWWINDOW;
    startup_info.wShowWindow = SW_SHOWNORMAL;

    PROCESS_INFORMATION process_info = {};
    const std::wstring working_directory = executable.parent_path().wstring();
    const BOOL created = CreateProcessW(
        executable_path.c_str(), command_line.data(), nullptr, nullptr, FALSE,
        0, nullptr,
        working_directory.empty() ? nullptr : working_directory.c_str(),
        &startup_info, &process_info);
    if (!created) {
      return false;
    }

    CloseHandle(process_info.hThread);
    CloseHandle(process_info.hProcess);
    return true;
  }
  static bool LaunchAIAssistant(AIAssistantStandaloneMode mode);

  static bool check_update() {
    // when checked manually, show testing versions too
    std::string feed_url = GetCustomResource("ManualUpdateFeedURL", "APPCAST");
    std::wstring channel{};
    auto ret = RegGetStringValue(HKEY_CURRENT_USER, L"Software\\Rime\\Weasel",
                                 L"UpdateChannel", channel);
    if (!ret && channel == L"testing") {
      feed_url = GetCustomResource("TestingManualUpdateFeedURL", "APPCAST");
    }
    if (!feed_url.empty()) {
      win_sparkle_set_appcast_url(feed_url.c_str());
    }
    win_sparkle_check_update_with_ui();
    return true;
  }

  static fs::path install_dir() {
    WCHAR exe_path[MAX_PATH] = {0};
    GetModuleFileNameW(GetModuleHandle(NULL), exe_path, _countof(exe_path));
    return fs::path(exe_path).remove_filename();
  }

 public:
  WeaselServerApp();
  ~WeaselServerApp();
  int Run();

 protected:
  void SetupMenuHandlers();

  weasel::Server m_server;
  weasel::UI m_ui;
  WeaselTrayIcon tray_icon;
  std::unique_ptr<RimeWithWeaselHandler> m_handler;
  DevConsole m_dev_console;
  std::unique_ptr<ContextHistory> m_context_history;
  std::unique_ptr<MemoryCompressor> m_memory_compressor;
};
