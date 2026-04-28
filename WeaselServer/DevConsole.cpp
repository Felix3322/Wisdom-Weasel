#include "stdafx.h"
#include "AuditLogger.h"
#include "DevConsole.h"
#include <WeaselUtility.h>
#include <rime_api.h>
#include <io.h>
#include <fcntl.h>
#include <iostream>
#include <sstream>

DevConsole::DevConsole()
    : m_enabled(false),
      m_console_allocated(false),
      m_hConsoleOutput(INVALID_HANDLE_VALUE),
      m_hConsoleInput(INVALID_HANDLE_VALUE) {}

DevConsole::~DevConsole() {
  Close();
}

bool DevConsole::Initialize() {
  // 从配置文件读取是否启用
  if (!LoadConfig()) {
    // 配置加载失败，可能是rime_api还未初始化或配置文件不存在
    // 静默失败，不启用开发终端
    return false;
  }

  if (!m_enabled) {
    // 配置项不存在或为false，不启用开发终端
    return false;
  }

  // 分配控制台窗口
  if (!AllocateConsole()) {
    // AllocConsole失败，可能是GUI应用无法分配控制台
    // 静默失败，不启用开发终端
    return false;
  }

  // 重定向标准输出
  if (!RedirectStdout()) {
    FreeConsole();
    return false;
  }

  // 设置控制台标题
  std::wstring title = L"Weasel 开发终端 - 调试日志";
  SetConsoleTitleW(title.c_str());

  // 设置控制台编码为UTF-8
  SetConsoleOutputCP(65001);  // UTF-8

  // 输出欢迎信息
  WriteLine("========================================");
  WriteLine("Weasel 开发终端已启动");
  WriteLine("实时显示调试日志输出");
  WriteLine("========================================");
  WriteLine("");

  return true;
}

bool DevConsole::LoadConfig() {
  RimeApi* rime_api = rime_get_api();
  if (!rime_api) {
    // rime_api未初始化，默认启用开发终端
    m_enabled = true;
    return true;
  }

  // 尝试打开weasel配置文件
  RimeConfig config = {NULL};
  if (!rime_api->config_open("weasel", &config)) {
    // 配置文件打开失败，默认启用开发终端
    m_enabled = true;
    return true;
  }

  Bool enabled = true;  // 默认值为true
  // 读取 dev_console/enabled 配置项
  // 如果配置项存在且为false，则禁用开发终端
  // 如果配置项不存在，默认启用（enabled保持为true）
  if (rime_api->config_get_bool(&config, "dev_console/enabled", &enabled)) {
    m_enabled = !!enabled;
  } else {
    // 配置项不存在，默认启用
    m_enabled = true;
  }

  rime_api->config_close(&config);
  return true;
}

bool DevConsole::AllocateConsole() {
  // 尝试分配新的控制台
  if (!::AllocConsole()) {
    DWORD error = GetLastError();
    // 如果已经存在控制台（ERROR_ACCESS_DENIED），尝试获取现有控制台
    if (error == ERROR_ACCESS_DENIED) {
      // 尝试获取标准输出句柄
      m_hConsoleOutput = GetStdHandle(STD_OUTPUT_HANDLE);
      if (m_hConsoleOutput != INVALID_HANDLE_VALUE &&
          m_hConsoleOutput != NULL) {
        m_console_allocated = false;  // 使用现有控制台
        return true;
      }
    }
    // AllocConsole失败，可能是GUI应用没有控制台
    // 尝试附加到父进程的控制台（如果是从命令行启动的）
    if (AttachConsole(ATTACH_PARENT_PROCESS)) {
      m_console_allocated = false;  // 使用父进程控制台
      m_hConsoleOutput = GetStdHandle(STD_OUTPUT_HANDLE);
      if (m_hConsoleOutput != INVALID_HANDLE_VALUE &&
          m_hConsoleOutput != NULL) {
        return true;
      }
      FreeConsole();  // 附加失败，释放
    }
    return false;
  }

  m_console_allocated = true;
  m_hConsoleOutput = GetStdHandle(STD_OUTPUT_HANDLE);
  m_hConsoleInput = GetStdHandle(STD_INPUT_HANDLE);

  if (m_hConsoleOutput == INVALID_HANDLE_VALUE ||
      m_hConsoleOutput == NULL) {
    FreeConsole();
    return false;
  }

  return true;
}

void DevConsole::FreeConsole() {
  if (m_console_allocated && ::FreeConsole()) {
    m_console_allocated = false;
  }
  m_hConsoleOutput = INVALID_HANDLE_VALUE;
  m_hConsoleInput = INVALID_HANDLE_VALUE;
}

bool DevConsole::RedirectStdout() {
  // 重定向标准输出到控制台
  FILE* fp = nullptr;
  freopen_s(&fp, "CONOUT$", "w", stdout);
  if (!fp) {
    return false;
  }

  // 重定向标准错误输出
  freopen_s(&fp, "CONOUT$", "w", stderr);
  if (!fp) {
    return false;
  }

  // 确保输出缓冲区立即刷新
  std::cout.setf(std::ios::unitbuf);
  std::cerr.setf(std::ios::unitbuf);

  return true;
}

void DevConsole::RestoreStdout() {
  // 恢复标准输出（如果需要的话）
  // 注意：在Windows GUI应用中，通常不需要恢复
}

void DevConsole::Write(const std::string& message) {
  if (!m_enabled || m_hConsoleOutput == INVALID_HANDLE_VALUE) {
    return;
  }

  DWORD written = 0;
  WriteFile(m_hConsoleOutput, message.c_str(),
            static_cast<DWORD>(message.length()), &written, NULL);
}

void DevConsole::WriteLine(const std::string& message) {
  AuditLogger::LogRawLine(message);
  Write(message);
  Write("\r\n");
}

void DevConsole::Write(const std::wstring& message) {
  if (!m_enabled || m_hConsoleOutput == INVALID_HANDLE_VALUE) {
    return;
  }

  // 将宽字符串转换为UTF-8
  int size_needed = WideCharToMultiByte(CP_UTF8, 0, message.c_str(),
                                        -1, NULL, 0, NULL, NULL);
  if (size_needed <= 0) {
    return;
  }

  std::string utf8_message(size_needed, 0);
  WideCharToMultiByte(CP_UTF8, 0, message.c_str(), -1,
                      &utf8_message[0], size_needed, NULL, NULL);

  // 移除末尾的null字符
  if (!utf8_message.empty() && utf8_message.back() == '\0') {
    utf8_message.pop_back();
  }

  Write(utf8_message);
}

void DevConsole::WriteLine(const std::wstring& message) {
  AuditLogger::LogRawLine(message);
  Write(message);
  Write("\r\n");
}

void DevConsole::Close() {
  if (m_enabled) {
    WriteLine("");
    WriteLine("========================================");
    WriteLine("Weasel 开发终端正在关闭...");
    WriteLine("========================================");
  }

  RestoreStdout();
  FreeConsole();
  m_enabled = false;
}

