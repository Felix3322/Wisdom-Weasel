#include "stdafx.h"
#include "AIAssistantStandalone.h"

#include "AuditLogger.h"
#include "AIAssistantDialog.h"
#include "AIAssistantService.h"

#include <WeaselConstants.h>
#include <WeaselUtility.h>
#include <rime_api.h>

namespace {

bool CommandEquals(const wchar_t* cmd_line, const wchar_t* expected) {
  return cmd_line && expected && !wcscmp(cmd_line, expected);
}

void SetupStandaloneRimeConfig() {
  RimeApi* rime_api = rime_get_api();
  if (!rime_api) {
    return;
  }

  RIME_STRUCT(RimeTraits, weasel_traits);
  std::string shared_dir = wtou8(WeaselSharedDataPath().wstring());
  std::string user_dir = wtou8(WeaselUserDataPath().wstring());
  std::string distribution_name = wtou8(get_weasel_ime_name());
  std::string log_dir = WeaselLogPath().u8string();

  weasel_traits.shared_data_dir = shared_dir.c_str();
  weasel_traits.user_data_dir = user_dir.c_str();
  weasel_traits.prebuilt_data_dir = weasel_traits.shared_data_dir;
  weasel_traits.distribution_name = distribution_name.c_str();
  weasel_traits.distribution_code_name = WEASEL_CODE_NAME;
  weasel_traits.distribution_version = WEASEL_VERSION;
  weasel_traits.app_name = "rime.weasel";
  weasel_traits.log_dir = log_dir.c_str();
  rime_api->setup(&weasel_traits);
  rime_api->initialize(nullptr);
}

void FinalizeStandaloneRimeConfig() {
  if (RimeApi* rime_api = rime_get_api()) {
    rime_api->finalize();
  }
}

class ScopedStandaloneRimeConfig {
 public:
  ScopedStandaloneRimeConfig() { SetupStandaloneRimeConfig(); }
  ~ScopedStandaloneRimeConfig() { FinalizeStandaloneRimeConfig(); }
};

}  // namespace

bool IsAIAssistantStandaloneCommandLine(const wchar_t* cmd_line) {
  return CommandEquals(cmd_line, L"/aiassistant") ||
         CommandEquals(cmd_line, L"/aiassistant-chat") ||
         CommandEquals(cmd_line, L"/aiassistant-polish") ||
         CommandEquals(cmd_line, L"/aiassistant-asr") ||
         CommandEquals(cmd_line, L"/chat") ||
         CommandEquals(cmd_line, L"/polish") ||
         CommandEquals(cmd_line, L"/asr");
}

AIAssistantStandaloneMode ParseAIAssistantStandaloneMode(
    const wchar_t* cmd_line) {
  if (CommandEquals(cmd_line, L"/aiassistant-polish") ||
      CommandEquals(cmd_line, L"/polish")) {
    return AIAssistantStandaloneMode::Polish;
  }
  if (CommandEquals(cmd_line, L"/aiassistant-asr") ||
      CommandEquals(cmd_line, L"/asr")) {
    return AIAssistantStandaloneMode::Asr;
  }
  return AIAssistantStandaloneMode::Chat;
}

std::wstring GetAIAssistantStandaloneArgument(
    AIAssistantStandaloneMode mode) {
  switch (mode) {
    case AIAssistantStandaloneMode::Polish:
      return L"/polish";
    case AIAssistantStandaloneMode::Asr:
      return L"/asr";
    case AIAssistantStandaloneMode::Chat:
    default:
      return L"/chat";
  }
}

int RunStandaloneAIAssistant(AIAssistantStandaloneMode mode) {
  CreateDirectory(WeaselUserDataPath().c_str(), nullptr);
  ScopedStandaloneRimeConfig rime_config;
  AuditLogger::Initialize();
  AuditLogger::Log(L"ai_assistant",
                   L"standalone assistant launched, mode=" +
                       GetAIAssistantStandaloneArgument(mode));

  AIAssistantService service;
  service.LoadConfig("weasel");

  AIAssistantDialog dialog(&service);
  dialog.SetInitialModeIndex(static_cast<int>(mode));
  dialog.DoModal(nullptr);
  AuditLogger::Log(L"ai_assistant", L"standalone assistant dialog closed");
  return 0;
}
