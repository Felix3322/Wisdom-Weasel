#pragma once

#include <string>

enum class AIAssistantStandaloneMode : int {
  Chat = 0,
  Polish = 1,
  Asr = 2,
};

bool IsAIAssistantStandaloneCommandLine(const wchar_t* cmd_line);
AIAssistantStandaloneMode ParseAIAssistantStandaloneMode(
    const wchar_t* cmd_line);
std::wstring GetAIAssistantStandaloneArgument(
    AIAssistantStandaloneMode mode);
int RunStandaloneAIAssistant(AIAssistantStandaloneMode mode);
