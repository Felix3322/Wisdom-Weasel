// WeaselAIAssistant.cpp : main source file for WeaselAIAssistant.exe

#include "../WeaselServer/stdafx.h"
#include "../WeaselServer/AIAssistantStandalone.h"

#include <WeaselUtility.h>
#include <ShellScalingApi.h>
#include <WinUser.h>

#pragma comment(lib, "Shcore.lib")

CAppModule _Module;

int WINAPI _tWinMain(HINSTANCE hInstance,
                     HINSTANCE /*hPrevInstance*/,
                     LPTSTR lpstrCmdLine,
                     int /*nCmdShow*/) {
  LANGID lang_id = get_language_id();
  SetThreadUILanguage(lang_id);
  SetThreadLocale(lang_id);

  if (!IsWindowsBlueOrLaterEx()) {
    MessageBoxExW(nullptr, L"仅支持 Windows 8.1 或更高版本系统。", L"系统版本过低",
                  MB_ICONERROR, lang_id);
    return 0;
  }
  SetProcessDpiAwareness(PROCESS_PER_MONITOR_DPI_AWARE);

  ImmDisableIME(-1);

  WCHAR user_name[20] = {0};
  DWORD size = _countof(user_name);
  GetUserNameW(user_name, &size);
  if (!_wcsicmp(user_name, L"SYSTEM")) {
    return 1;
  }

  HRESULT hr = ::CoInitialize(nullptr);
  ATLASSERT(SUCCEEDED(hr));

  ::DefWindowProc(nullptr, 0, 0, 0L);
  AtlInitCommonControls(ICC_BAR_CLASSES);

  hr = _Module.Init(nullptr, hInstance);
  ATLASSERT(SUCCEEDED(hr));

  const AIAssistantStandaloneMode mode =
      ParseAIAssistantStandaloneMode(lpstrCmdLine);
  const int ret = RunStandaloneAIAssistant(mode);

  _Module.Term();
  ::CoUninitialize();
  return ret;
}
