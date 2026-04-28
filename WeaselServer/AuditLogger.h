#pragma once

#include <Windows.h>

#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>
#include <system_error>

#include <WeaselUtility.h>
#include <rime_api.h>

class AuditLogger {
 public:
  static void Initialize() {
    std::lock_guard<std::mutex> lock(s_mutex);
    RefreshStateLocked();
  }

  static bool IsEnabled() {
    std::lock_guard<std::mutex> lock(s_mutex);
    RefreshStateLocked();
    return s_enabled;
  }

  static std::wstring GetLogPath() {
    std::lock_guard<std::mutex> lock(s_mutex);
    RefreshStateLocked();
    return s_log_path;
  }

  static void Log(const std::wstring& module, const std::wstring& message) {
    std::lock_guard<std::mutex> lock(s_mutex);
    RefreshStateLocked();
    if (!s_enabled) {
      return;
    }

    std::wstring line = L"[";
    line += ToWideTimestamp(current_time());
    line += L"]";
    if (!module.empty()) {
      line += L"[";
      line += module;
      line += L"] ";
    } else {
      line += L" ";
    }
    line += message;
    WriteLineLocked(line);
  }

  static void Log(const std::string& module, const std::string& message) {
    Log(u8tow(module), u8tow(message));
  }

  static void LogRawLine(const std::wstring& message) {
    std::lock_guard<std::mutex> lock(s_mutex);
    RefreshStateLocked();
    if (!s_enabled) {
      return;
    }

    std::wstring line = L"[";
    line += ToWideTimestamp(current_time());
    line += L"] ";
    line += message;
    WriteLineLocked(line);
  }

  static void LogRawLine(const std::string& message) {
    LogRawLine(u8tow(message));
  }

 private:
  inline static std::mutex s_mutex;
  inline static bool s_enabled = true;
  inline static bool s_initialized = false;
  inline static bool s_header_written = false;
  inline static std::wstring s_log_path;

  static std::wstring ToWideTimestamp(const std::string& ascii) {
    return std::wstring(ascii.begin(), ascii.end());
  }

  static std::wstring DefaultLogPath() {
    return (WeaselLogPath() / L"weasel.audit.log").wstring();
  }

  static std::wstring NormalizeConfiguredPath(const std::string& configured_path) {
    if (configured_path.empty()) {
      return DefaultLogPath();
    }

    std::filesystem::path path = std::filesystem::u8path(configured_path);
    if (path.is_relative()) {
      path = WeaselLogPath() / path;
    }
    return path.lexically_normal().wstring();
  }

  static void SetLuaBridgeEnvironmentLocked() {
    ::SetEnvironmentVariableW(L"WEASEL_SERVER_AUDIT_ENABLED",
                              s_enabled ? L"1" : L"0");
    ::SetEnvironmentVariableW(
        L"WEASEL_SERVER_AUDIT_LOG_PATH",
        s_enabled && !s_log_path.empty() ? s_log_path.c_str() : nullptr);
  }

  static void RefreshStateLocked() {
    bool enabled = true;
    std::wstring log_path = DefaultLogPath();

    if (RimeApi* rime_api = rime_get_api()) {
      RimeConfig config = {0};
      if (rime_api->config_open("weasel", &config)) {
        Bool configured_enabled = true;
        if (rime_api->config_get_bool &&
            rime_api->config_get_bool(&config, "server_audit/enabled",
                                      &configured_enabled)) {
          enabled = !!configured_enabled;
        }

        char buffer[1024] = {0};
        if (rime_api->config_get_string &&
            rime_api->config_get_string(&config, "server_audit/path", buffer,
                                        sizeof(buffer) - 1) &&
            buffer[0] != '\0') {
          log_path = NormalizeConfiguredPath(buffer);
        }
        rime_api->config_close(&config);
      }
    }

    const bool changed =
        !s_initialized || s_enabled != enabled || s_log_path != log_path;
    s_enabled = enabled;
    s_log_path = log_path;
    s_initialized = true;
    SetLuaBridgeEnvironmentLocked();

    if (!s_enabled || s_log_path.empty()) {
      return;
    }

    const std::filesystem::path path(s_log_path);
    std::error_code ec;
    if (!path.parent_path().empty()) {
      std::filesystem::create_directories(path.parent_path(), ec);
    }

    if (changed) {
      s_header_written = false;
    }
    if (!s_header_written) {
      std::wstring header = L"[";
      header += ToWideTimestamp(current_time());
      header += L"] [server_audit] started, pid=" +
                std::to_wstring(GetCurrentProcessId()) + L", path=" + s_log_path;
      WriteLineLocked(header);
      s_header_written = true;
    }
  }

  static void RotateIfNeededLocked() {
    const std::filesystem::path path(s_log_path);
    std::error_code ec;
    if (!std::filesystem::exists(path, ec)) {
      return;
    }

    constexpr std::uintmax_t kMaxAuditLogBytes = 8ULL * 1024ULL * 1024ULL;
    const std::uintmax_t file_size = std::filesystem::file_size(path, ec);
    if (ec || file_size < kMaxAuditLogBytes) {
      return;
    }

    std::filesystem::path backup = path;
    backup += L".1";
    std::filesystem::remove(backup, ec);
    ec.clear();
    std::filesystem::rename(path, backup, ec);
  }

  static void WriteLineLocked(const std::wstring& line) {
    if (!s_enabled || s_log_path.empty()) {
      return;
    }

    RotateIfNeededLocked();
    std::ofstream stream(std::filesystem::path(s_log_path),
                         std::ios::binary | std::ios::app);
    if (!stream.is_open()) {
      return;
    }
    stream << wtou8(line) << "\r\n";
  }
};
