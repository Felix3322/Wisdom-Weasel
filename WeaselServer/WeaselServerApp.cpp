#include "stdafx.h"
#include "AIAssistantStandalone.h"
#include "AuditLogger.h"
#include "WeaselServerApp.h"
#include <filesystem>
#include <rime_api.h>

WeaselServerApp::WeaselServerApp()
    : m_handler(std::make_unique<RimeWithWeaselHandler>(&m_ui)),
      tray_icon(m_ui) {
  // m_handler.reset(new RimeWithWeaselHandler(&m_ui));
  m_server.SetRequestHandler(m_handler.get());
  SetupMenuHandlers();
}

WeaselServerApp::~WeaselServerApp() {}

bool WeaselServerApp::LaunchAIAssistant(AIAssistantStandaloneMode mode) {
  const std::filesystem::path dir = install_dir();
  if (launch_binary(dir / L"WeaselAIAssistant.exe",
                    GetAIAssistantStandaloneArgument(mode))) {
    return true;
  }

  switch (mode) {
    case AIAssistantStandaloneMode::Polish:
      return launch_self(L"/aiassistant-polish");
    case AIAssistantStandaloneMode::Asr:
      return launch_self(L"/aiassistant-asr");
    case AIAssistantStandaloneMode::Chat:
    default:
      return launch_self(L"/aiassistant");
  }
}

int WeaselServerApp::Run() {
  if (!m_server.Start())
    return -1;

  // win_sparkle_set_appcast_url("http://localhost:8000/weasel/update/appcast.xml");
  win_sparkle_set_registry_path("Software\\Rime\\Weasel\\Updates");
  if (GetThreadUILanguage() ==
      MAKELANGID(LANG_CHINESE, SUBLANG_CHINESE_TRADITIONAL))
    win_sparkle_set_lang("zh-TW");
  else if (GetThreadUILanguage() ==
           MAKELANGID(LANG_CHINESE, SUBLANG_CHINESE_SIMPLIFIED))
    win_sparkle_set_lang("zh-CN");
  else
    win_sparkle_set_lang("en");
  win_sparkle_init();
  m_ui.Create(m_server.GetHWnd());
  AuditLogger::Initialize();

  // 先初始化Rime（需要先initialize才能读取配置）
  m_handler->Initialize();
  AuditLogger::Initialize();
  AuditLogger::Log(L"server",
                   L"WeaselServerApp::Run initialized Rime and audit logger");
  
  // 初始化开发终端（需要在rime_api->initialize()之后，才能读取配置）
  m_dev_console.Initialize();
  // 先设置全局 g_dev_console，以便 MemoryCompressor 等加载时能输出记忆相关日志
  m_handler->SetDevConsole(&m_dev_console);
  
  // 创建上下文历史记录（最大50个词，超过时异步压缩旧25词，即一半）
  m_context_history = std::make_unique<ContextHistory>(50);
  
  // 记忆压缩 LLM（从 weasel 配置 llm/memory/ 单独配置）
  m_memory_compressor = std::make_unique<MemoryCompressor>();
  m_memory_compressor->LoadConfig("weasel");
  m_context_history->SetMemoryCompressor(m_memory_compressor.get());

  // 将上下文历史记录传递给 handler
  m_handler->SetContextHistory(m_context_history.get());
  m_handler->SetAIAssistantMenuInvoker(
      []() { WeaselServerApp::LaunchAIAssistant(AIAssistantStandaloneMode::Chat); });
  
  m_handler->OnUpdateUI([this]() { tray_icon.Refresh(); });

  tray_icon.Create(m_server.GetHWnd());
  tray_icon.Refresh();

  int ret = m_server.Run();
  AuditLogger::Log(L"server",
                   L"WeaselServerApp::Run message loop exited, code=" +
                       std::to_wstring(ret));

  m_handler->Finalize();
  m_ui.Destroy();
  tray_icon.RemoveIcon();
  m_dev_console.Close();
  win_sparkle_cleanup();

  return ret;
}

void WeaselServerApp::SetupMenuHandlers() {
  std::filesystem::path dir = install_dir();
  m_server.AddMenuHandler(ID_WEASELTRAY_QUIT,
                          [this] { return m_server.Stop() == 0; });
  m_server.AddMenuHandler(ID_WEASELTRAY_DEPLOY,
                          std::bind(execute, dir / L"WeaselDeployer.exe",
                                    std::wstring(L"/deploy")));
  m_server.AddMenuHandler(
      ID_WEASELTRAY_SETTINGS,
      std::bind(execute, dir / L"WeaselDeployer.exe", std::wstring()));
  m_server.AddMenuHandler(
      ID_WEASELTRAY_DICT_MANAGEMENT,
      std::bind(execute, dir / L"WeaselDeployer.exe", std::wstring(L"/dict")));
  m_server.AddMenuHandler(
      ID_WEASELTRAY_SYNC,
      std::bind(execute, dir / L"WeaselDeployer.exe", std::wstring(L"/sync")));
  m_server.AddMenuHandler(ID_WEASELTRAY_WIKI,
                          std::bind(open, L"https://rime.im/docs/"));
  m_server.AddMenuHandler(ID_WEASELTRAY_HOMEPAGE,
                          std::bind(open, L"https://rime.im/"));
  m_server.AddMenuHandler(ID_WEASELTRAY_FORUM,
                          std::bind(open, L"https://rime.im/discuss/"));
  m_server.AddMenuHandler(ID_WEASELTRAY_CHECKUPDATE, check_update);
  m_server.AddMenuHandler(ID_WEASELTRAY_INSTALLDIR, std::bind(explore, dir));
  m_server.AddMenuHandler(ID_WEASELTRAY_USERCONFIG,
                          std::bind(explore, WeaselUserDataPath()));
  m_server.AddMenuHandler(ID_WEASELTRAY_LOGDIR,
                          std::bind(explore, WeaselLogPath()));
  m_server.AddMenuHandler(ID_WEASELTRAY_AI_ASSISTANT,
                          []() {
                            return WeaselServerApp::LaunchAIAssistant(
                                AIAssistantStandaloneMode::Chat);
                          });
}
