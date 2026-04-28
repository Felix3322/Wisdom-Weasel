#include "stdafx.h"
#include "AIAssistantDialog.h"

#include <algorithm>
#include <cwctype>
#include <dwmapi.h>
#include <shobjidl.h>
#include <uxtheme.h>
#include <vector>

#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "uxtheme.lib")

namespace {

constexpr COLORREF kWindowBackground = RGB(242, 246, 252);
constexpr COLORREF kPanelBackground = RGB(255, 255, 255);
constexpr COLORREF kReadOnlyPanelBackground = RGB(247, 250, 255);
constexpr COLORREF kBorderColor = RGB(214, 223, 236);
constexpr COLORREF kTextPrimary = RGB(28, 34, 44);
constexpr COLORREF kTextSecondary = RGB(92, 103, 118);
constexpr COLORREF kAccentPrimary = RGB(50, 115, 220);
constexpr COLORREF kAccentSoft = RGB(231, 240, 255);
constexpr COLORREF kSuccessColor = RGB(28, 138, 88);
constexpr COLORREF kErrorColor = RGB(201, 70, 62);
constexpr COLORREF kButtonNeutral = RGB(244, 247, 251);
constexpr COLORREF kButtonNeutralBorder = RGB(216, 224, 235);
constexpr COLORREF kCloseButtonColor = RGB(229, 236, 246);
constexpr int kWindowCornerRadius = 24;
constexpr int kCardRadius = 18;
constexpr int kEditRadius = 14;

template <typename TInterface, typename TDialog>
std::wstring SelectFile(HWND owner,
                        LPCWSTR title,
                        UINT filter_size,
                        COMDLG_FILTERSPEC filters[]) {
  std::wstring selected_path;
  const HRESULT init_result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  CComPtr<TInterface> dialog;
  if (SUCCEEDED(dialog.CoCreateInstance(__uuidof(TDialog)))) {
    dialog->SetTitle(title);
    dialog->SetFileTypes(filter_size, filters);
    if (SUCCEEDED(dialog->Show(owner))) {
      CComPtr<IShellItem> result;
      if (SUCCEEDED(dialog->GetResult(&result))) {
        wchar_t* raw_path = nullptr;
        if (SUCCEEDED(
                result->GetDisplayName(SIGDN_FILESYSPATH, &raw_path)) &&
            raw_path) {
          selected_path = raw_path;
          CoTaskMemFree(raw_path);
        }
      }
    }
  }

  if (SUCCEEDED(init_result)) {
    CoUninitialize();
  }
  return selected_path;
}

std::wstring TrimWhitespace(std::wstring text) {
  auto not_space = [](wchar_t ch) { return !iswspace(ch); };
  text.erase(text.begin(), std::find_if(text.begin(), text.end(), not_space));
  text.erase(std::find_if(text.rbegin(), text.rend(), not_space).base(),
             text.end());
  return text;
}

LOGFONTW BuildUiFont(int point_size, int weight, const wchar_t* face_name) {
  LOGFONTW lf = {};
  lf.lfHeight = -MulDiv(point_size, GetDeviceCaps(::GetDC(nullptr), LOGPIXELSY),
                        72);
  lf.lfWeight = weight;
  lf.lfQuality = CLEARTYPE_QUALITY;
  wcscpy_s(lf.lfFaceName, face_name);
  return lf;
}

void FillSolidRect(HDC hdc, const RECT& rect, COLORREF color) {
  HBRUSH brush = ::CreateSolidBrush(color);
  ::FillRect(hdc, &rect, brush);
  ::DeleteObject(brush);
}

}  // namespace

AIAssistantDialog::AIAssistantDialog(AIAssistantService* service)
    : m_service(service) {}

AIAssistantDialog::~AIAssistantDialog() = default;

void AIAssistantDialog::SetInitialModeIndex(int mode_index) {
  m_initial_mode_index = mode_index;
}

LRESULT AIAssistantDialog::OnInitDialog(UINT, WPARAM, LPARAM, BOOL&) {
  m_mode_combo.Attach(GetDlgItem(IDC_AI_MODE));
  m_tone_combo.Attach(GetDlgItem(IDC_AI_TONE));
  m_history_edit.Attach(GetDlgItem(IDC_AI_HISTORY));
  m_input_edit.Attach(GetDlgItem(IDC_AI_INPUT));
  m_result_edit.Attach(GetDlgItem(IDC_AI_RESULT));
  m_file_path_edit.Attach(GetDlgItem(IDC_AI_FILEPATH));
  m_browse_button.Attach(GetDlgItem(IDC_AI_BROWSE));
  m_run_button.Attach(GetDlgItem(IDC_AI_RUN));
  m_copy_button.Attach(GetDlgItem(IDC_AI_COPY));
  m_clear_button.Attach(GetDlgItem(IDC_AI_CLEAR));
  m_close_button.Attach(GetDlgItem(IDC_AI_CLOSE));

  m_mode_combo.AddString(L"AI 对话");
  m_mode_combo.AddString(L"语气润色");
  m_mode_combo.AddString(L"音频转写");
  const int bounded_index =
      (m_initial_mode_index >= 0 && m_initial_mode_index <= 2)
          ? m_initial_mode_index
          : 0;
  m_mode_combo.SetCurSel(bounded_index);

  m_tone_combo.AddString(L"可爱一点");
  m_tone_combo.AddString(L"正式一点");
  m_tone_combo.AddString(L"严谨一点");
  m_tone_combo.AddString(L"搞怪一点");
  m_tone_combo.SetCurSel(0);

  m_history_edit.SetReadOnly(TRUE);
  m_result_edit.SetReadOnly(TRUE);
  m_visual_dpi = GetCurrentDpi();

  RefreshFonts();
  ApplyWindowChrome();
  ApplyControlStyling();
  InitCtrlRects();
  LayoutControls();
  UpdateRoundedRegions();

  if (m_service) {
    SetStatusText(m_service->GetAvailabilityHint());
  } else {
    SetStatusText(L"AI 助手服务未初始化。");
  }

  ApplyModeUI();
  CenterWindow();
  ShowWindow(SW_SHOWNORMAL);
  SetForegroundWindow(m_hWnd);
  SetActiveWindow();
  BringWindowToTop();
  return TRUE;
}

LRESULT AIAssistantDialog::OnClose(UINT, WPARAM, LPARAM, BOOL&) {
  EndDialog(IDCANCEL);
  return 0;
}

LRESULT AIAssistantDialog::OnDestroy(UINT, WPARAM, LPARAM, BOOL&) {
  if (m_title_font) {
    ::DeleteObject(m_title_font);
    m_title_font = nullptr;
  }
  if (m_subtitle_font) {
    ::DeleteObject(m_subtitle_font);
    m_subtitle_font = nullptr;
  }
  if (m_button_font) {
    ::DeleteObject(m_button_font);
    m_button_font = nullptr;
  }
  if (m_window_brush) {
    ::DeleteObject(m_window_brush);
    m_window_brush = nullptr;
  }
  if (m_surface_brush) {
    ::DeleteObject(m_surface_brush);
    m_surface_brush = nullptr;
  }
  if (m_readonly_surface_brush) {
    ::DeleteObject(m_readonly_surface_brush);
    m_readonly_surface_brush = nullptr;
  }
  return 0;
}

LRESULT AIAssistantDialog::OnCloseCommand(WORD, WORD code, HWND, BOOL&) {
  EndDialog(code);
  return 0;
}

LRESULT AIAssistantDialog::OnRun(WORD, WORD, HWND, BOOL&) {
  if (!m_service || !m_service->IsEnabled()) {
    m_status_tone = StatusTone::Error;
    SetStatusText(L"AI 助手未启用，请先配置 assistant/enabled: true。");
    return 0;
  }

  const Mode mode = GetCurrentMode();
  std::wstring result_text;
  std::wstring error_text;
  m_status_tone = StatusTone::Neutral;
  SetStatusText(L"处理中...");

  switch (mode) {
    case Mode::Chat: {
      const std::wstring user_text =
          TrimWhitespace(GetTextFromEdit(m_input_edit));
      if (user_text.empty()) {
        m_status_tone = StatusTone::Error;
        SetStatusText(L"请输入对话内容。");
        return 0;
      }
      if (m_service->Chat(m_conversation_history, user_text, result_text,
                          error_text)) {
        m_conversation_history.push_back({L"user", user_text});
        m_conversation_history.push_back({L"assistant", result_text});
        RefreshConversationHistory();
        m_input_edit.SetWindowTextW(L"");
        SetResultText(result_text);
        m_status_tone = StatusTone::Success;
        SetStatusText(L"对话完成。");
      } else {
        m_status_tone = StatusTone::Error;
        SetStatusText(error_text);
      }
      break;
    }
    case Mode::Polish: {
      const std::wstring input_text =
          TrimWhitespace(GetTextFromEdit(m_input_edit));
      if (input_text.empty()) {
        m_status_tone = StatusTone::Error;
        SetStatusText(L"请输入要润色的内容。");
        return 0;
      }
      if (m_service->Polish(input_text, GetSelectedTone(), result_text,
                            error_text)) {
        SetResultText(result_text);
        m_status_tone = StatusTone::Success;
        SetStatusText(L"润色完成。");
      } else {
        m_status_tone = StatusTone::Error;
        SetStatusText(error_text);
      }
      break;
    }
    case Mode::Asr: {
      const std::wstring file_path =
          TrimWhitespace(GetTextFromEdit(m_file_path_edit));
      if (file_path.empty()) {
        m_status_tone = StatusTone::Error;
        SetStatusText(L"请先选择音频文件。");
        return 0;
      }
      if (m_service->TranscribeAudioFile(file_path, result_text, error_text)) {
        SetResultText(result_text);
        m_status_tone = StatusTone::Success;
        SetStatusText(L"音频转写完成。");
      } else {
        m_status_tone = StatusTone::Error;
        SetStatusText(error_text);
      }
      break;
    }
  }

  Invalidate();
  return 0;
}

LRESULT AIAssistantDialog::OnBrowseAudio(WORD, WORD, HWND, BOOL&) {
  static COMDLG_FILTERSPEC filters[] = {
      {L"音频文件 (*.wav;*.mp3;*.m4a;*.mp4;*.aac;*.ogg;*.flac;*.webm)",
       L"*.wav;*.mp3;*.m4a;*.mp4;*.aac;*.ogg;*.flac;*.webm"},
      {L"所有文件 (*.*)", L"*.*"}};

  const std::wstring selected_path =
      SelectFile<IFileOpenDialog, FileOpenDialog>(m_hWnd, L"选择待转写音频",
                                                  ARRAYSIZE(filters), filters);
  if (!selected_path.empty()) {
    m_file_path_edit.SetWindowTextW(selected_path.c_str());
    m_status_tone = StatusTone::Neutral;
    SetStatusText(L"已选择音频文件。");
  }
  return 0;
}

LRESULT AIAssistantDialog::OnCopyResult(WORD, WORD, HWND, BOOL&) {
  const std::wstring result_text = GetTextFromEdit(m_result_edit);
  if (result_text.empty()) {
    m_status_tone = StatusTone::Error;
    SetStatusText(L"当前没有可复制的结果。");
    return 0;
  }

  if (CopyTextToClipboard(result_text)) {
    m_status_tone = StatusTone::Success;
    SetStatusText(L"结果已复制到剪贴板。");
  } else {
    m_status_tone = StatusTone::Error;
    SetStatusText(L"复制失败。");
  }
  return 0;
}

LRESULT AIAssistantDialog::OnClear(WORD, WORD, HWND, BOOL&) {
  switch (GetCurrentMode()) {
    case Mode::Chat:
      m_conversation_history.clear();
      RefreshConversationHistory();
      m_input_edit.SetWindowTextW(L"");
      break;
    case Mode::Polish:
      m_input_edit.SetWindowTextW(L"");
      break;
    case Mode::Asr:
      m_file_path_edit.SetWindowTextW(L"");
      break;
  }
  SetResultText(L"");
  m_status_tone = StatusTone::Neutral;
  SetStatusText(L"已清空当前模式内容。");
  return 0;
}

LRESULT AIAssistantDialog::OnModeChanged(WORD, WORD, HWND, BOOL&) {
  ApplyModeUI();
  return 0;
}

LRESULT AIAssistantDialog::OnEraseBackground(UINT, WPARAM, LPARAM, BOOL&) {
  return 1;
}

LRESULT AIAssistantDialog::OnPaint(UINT, WPARAM, LPARAM, BOOL&) {
  CPaintDC dc(m_hWnd);
  RECT client_rect = {};
  GetClientRect(&client_rect);
  FillSolidRect(dc, client_rect, kWindowBackground);

  const int pad = Scale(16);
  const int header_height = Scale(74);
  const int footer_height = Scale(76);
  RECT shell_rect = {pad, pad, client_rect.right - pad, client_rect.bottom - pad};
  DrawRoundedBlock(dc, shell_rect, kPanelBackground, kBorderColor,
                   Scale(kWindowCornerRadius));

  RECT header_rect = shell_rect;
  header_rect.bottom = header_rect.top + header_height;
  FillSolidRect(dc, header_rect, RGB(249, 251, 255));

  HPEN divider_pen = ::CreatePen(PS_SOLID, 1, RGB(232, 238, 247));
  HPEN old_pen = static_cast<HPEN>(::SelectObject(dc, divider_pen));
  ::MoveToEx(dc, shell_rect.left + Scale(18), header_rect.bottom, nullptr);
  ::LineTo(dc, shell_rect.right - Scale(18), header_rect.bottom);
  RECT footer_rect = shell_rect;
  footer_rect.top = footer_rect.bottom - footer_height;
  ::MoveToEx(dc, shell_rect.left + Scale(18), footer_rect.top, nullptr);
  ::LineTo(dc, shell_rect.right - Scale(18), footer_rect.top);
  ::SelectObject(dc, old_pen);
  ::DeleteObject(divider_pen);

  dc.SetBkMode(TRANSPARENT);
  dc.SetTextColor(kTextPrimary);

  const RECT title_rect = {shell_rect.left + Scale(24), shell_rect.top + Scale(18),
                           shell_rect.left + Scale(220), shell_rect.top + Scale(46)};
  HFONT old_font = static_cast<HFONT>(::SelectObject(dc, m_title_font));
  dc.DrawText(L"AI 浮窗", -1, const_cast<RECT*>(&title_rect),
              DT_LEFT | DT_VCENTER | DT_SINGLELINE);

  dc.SetTextColor(kTextSecondary);
  const RECT subtitle_rect = {shell_rect.left + Scale(24), shell_rect.top + Scale(44),
                              shell_rect.left + Scale(320), shell_rect.top + Scale(64)};
  ::SelectObject(dc, m_subtitle_font);
  dc.DrawText(L"更轻、更顺手的本地智能助手", -1,
              const_cast<RECT*>(&subtitle_rect),
              DT_LEFT | DT_VCENTER | DT_SINGLELINE);
  ::SelectObject(dc, old_font);

  auto draw_card_title = [&](int label_id, const wchar_t* fallback_text) {
    HWND label = GetDlgItem(label_id);
    if (!label || !::IsWindowVisible(label)) {
      return;
    }
    std::wstring text = fallback_text;
    const int text_len = ::GetWindowTextLengthW(label);
    if (text_len > 0) {
      std::vector<wchar_t> buffer(static_cast<size_t>(text_len) + 1, L'\0');
      ::GetWindowTextW(label, buffer.data(), text_len + 1);
      text.assign(buffer.data());
    }
    RECT rect = GetControlRect(label_id);
    rect.left += Scale(4);
    dc.SetTextColor(kTextSecondary);
    HFONT saved = static_cast<HFONT>(::SelectObject(dc, m_subtitle_font));
    dc.DrawText(text.c_str(), -1, &rect, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    ::SelectObject(dc, saved);
  };

  draw_card_title(IDC_AI_LABEL_HISTORY, L"对话历史");
  draw_card_title(IDC_AI_LABEL_INPUT, L"输入内容");
  draw_card_title(IDC_AI_LABEL_RESULT, L"输出结果");
  draw_card_title(IDC_AI_LABEL_FILE, L"音频文件");
  draw_card_title(IDC_AI_LABEL_TONE, L"风格");

  return 0;
}

LRESULT AIAssistantDialog::OnSize(UINT, WPARAM, LPARAM, BOOL&) {
  LayoutControls();
  UpdateRoundedRegions();
  Invalidate();
  return 0;
}

LRESULT AIAssistantDialog::OnNcHitTest(UINT, WPARAM, LPARAM l_param, BOOL&) {
  const POINT screen_point = {GET_X_LPARAM(l_param), GET_Y_LPARAM(l_param)};
  RECT window_rect = {};
  GetWindowRect(&window_rect);

  const int grip = Scale(10);
  const bool on_left = screen_point.x < window_rect.left + grip;
  const bool on_right = screen_point.x >= window_rect.right - grip;
  const bool on_top = screen_point.y < window_rect.top + grip;
  const bool on_bottom = screen_point.y >= window_rect.bottom - grip;

  if (on_top && on_left) {
    return HTTOPLEFT;
  }
  if (on_top && on_right) {
    return HTTOPRIGHT;
  }
  if (on_bottom && on_left) {
    return HTBOTTOMLEFT;
  }
  if (on_bottom && on_right) {
    return HTBOTTOMRIGHT;
  }
  if (on_left) {
    return HTLEFT;
  }
  if (on_right) {
    return HTRIGHT;
  }
  if (on_top) {
    return HTTOP;
  }
  if (on_bottom) {
    return HTBOTTOM;
  }

  const POINT client_point = {screen_point.x - window_rect.left,
                              screen_point.y - window_rect.top};
  RECT close_rect = GetControlRect(IDC_AI_CLOSE);
  RECT mode_rect = GetControlRect(IDC_AI_MODE);
  RECT tone_rect = GetControlRect(IDC_AI_TONE);
  if (::PtInRect(&close_rect, client_point) || ::PtInRect(&mode_rect, client_point) ||
      ::PtInRect(&tone_rect, client_point)) {
    return HTCLIENT;
  }

  const int drag_height = Scale(72);
  if (client_point.y <= drag_height) {
    return HTCAPTION;
  }

  return HTCLIENT;
}

LRESULT AIAssistantDialog::OnCtlColorDialog(UINT, WPARAM w_param, LPARAM,
                                            BOOL&) {
  HDC hdc = reinterpret_cast<HDC>(w_param);
  ::SetBkColor(hdc, kWindowBackground);
  return reinterpret_cast<LRESULT>(m_window_brush);
}

LRESULT AIAssistantDialog::OnCtlColorStatic(UINT, WPARAM w_param, LPARAM l_param,
                                            BOOL&) {
  HDC hdc = reinterpret_cast<HDC>(w_param);
  HWND hwnd = reinterpret_cast<HWND>(l_param);
  ::SetBkMode(hdc, TRANSPARENT);

  if (hwnd == GetDlgItem(IDC_AI_STATUS)) {
    ::SetTextColor(hdc, GetStatusColor());
  } else if (hwnd == GetDlgItem(IDC_AI_LABEL_HISTORY) ||
             hwnd == GetDlgItem(IDC_AI_LABEL_INPUT) ||
             hwnd == GetDlgItem(IDC_AI_LABEL_RESULT) ||
             hwnd == GetDlgItem(IDC_AI_LABEL_FILE) ||
             hwnd == GetDlgItem(IDC_AI_LABEL_TONE)) {
    ::SetTextColor(hdc, kTextSecondary);
  } else {
    ::SetTextColor(hdc, kTextPrimary);
  }
  return reinterpret_cast<LRESULT>(m_window_brush);
}

LRESULT AIAssistantDialog::OnCtlColorEdit(UINT, WPARAM w_param, LPARAM l_param,
                                          BOOL&) {
  HDC hdc = reinterpret_cast<HDC>(w_param);
  HWND hwnd = reinterpret_cast<HWND>(l_param);
  const bool readonly =
      hwnd == m_history_edit.m_hWnd || hwnd == m_result_edit.m_hWnd;
  ::SetBkColor(hdc, readonly ? kReadOnlyPanelBackground : kPanelBackground);
  ::SetTextColor(hdc, kTextPrimary);
  return reinterpret_cast<LRESULT>(readonly ? m_readonly_surface_brush
                                            : m_surface_brush);
}

LRESULT AIAssistantDialog::OnCtlColorButton(UINT, WPARAM w_param, LPARAM,
                                            BOOL&) {
  HDC hdc = reinterpret_cast<HDC>(w_param);
  ::SetBkMode(hdc, TRANSPARENT);
  return reinterpret_cast<LRESULT>(m_window_brush);
}

LRESULT AIAssistantDialog::OnDrawItem(UINT, WPARAM, LPARAM l_param, BOOL&) {
  const DRAWITEMSTRUCT* dis =
      reinterpret_cast<const DRAWITEMSTRUCT*>(l_param);
  if (!dis) {
    return FALSE;
  }

  const bool selected =
      (dis->itemState & ODS_SELECTED) == ODS_SELECTED;
  const bool disabled =
      (dis->itemState & ODS_DISABLED) == ODS_DISABLED;
  const int radius = Scale(13);
  COLORREF fill = kButtonNeutral;
  COLORREF border = kButtonNeutralBorder;
  COLORREF text = kTextPrimary;

  switch (dis->CtlID) {
    case IDC_AI_RUN:
      fill = selected ? RGB(37, 94, 196) : GetAccentColor();
      border = fill;
      text = RGB(255, 255, 255);
      break;
    case IDC_AI_COPY:
    case IDC_AI_CLEAR:
    case IDC_AI_BROWSE:
      fill = selected ? RGB(236, 242, 250) : kButtonNeutral;
      border = kButtonNeutralBorder;
      break;
    case IDC_AI_CLOSE:
      fill = selected ? RGB(214, 224, 239) : kCloseButtonColor;
      border = fill;
      break;
    default:
      break;
  }

  if (disabled) {
    fill = RGB(235, 239, 245);
    border = RGB(225, 230, 238);
    text = RGB(148, 156, 168);
  }

  DrawRoundedBlock(dis->hDC, dis->rcItem, fill, border, radius);
  ::SetBkMode(dis->hDC, TRANSPARENT);
  ::SetTextColor(dis->hDC, text);
  HFONT old_font = static_cast<HFONT>(::SelectObject(dis->hDC, m_button_font));

  wchar_t caption[64] = {};
  ::GetWindowTextW(dis->hwndItem, caption, ARRAYSIZE(caption));
  RECT text_rect = dis->rcItem;
  if (dis->CtlID == IDC_AI_CLOSE) {
    wcscpy_s(caption, L"×");
  }
  ::DrawTextW(dis->hDC, caption, -1, &text_rect,
              DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  ::SelectObject(dis->hDC, old_font);
  return TRUE;
}

void AIAssistantDialog::ApplyModeUI() {
  const Mode mode = GetCurrentMode();
  const bool show_history = mode == Mode::Chat;
  const bool show_input = mode == Mode::Chat || mode == Mode::Polish;
  const bool show_tone = mode == Mode::Polish;
  const bool show_file = mode == Mode::Asr;

  ShowControl(IDC_AI_LABEL_HISTORY, show_history);
  ShowControl(IDC_AI_HISTORY, show_history);
  ShowControl(IDC_AI_LABEL_INPUT, show_input);
  ShowControl(IDC_AI_INPUT, show_input);
  ShowControl(IDC_AI_LABEL_TONE, show_tone);
  ShowControl(IDC_AI_TONE, show_tone);
  ShowControl(IDC_AI_LABEL_FILE, show_file);
  ShowControl(IDC_AI_FILEPATH, show_file);
  ShowControl(IDC_AI_BROWSE, show_file);

  switch (mode) {
    case Mode::Chat:
      SetTextForControl(IDC_AI_LABEL_INPUT, L"输入内容");
      SetTextForControl(IDC_AI_LABEL_RESULT, L"本轮回复");
      SetTextForControl(IDC_AI_RUN, L"发送");
      break;
    case Mode::Polish:
      SetTextForControl(IDC_AI_LABEL_INPUT, L"原始文本");
      SetTextForControl(IDC_AI_LABEL_RESULT, L"润色结果");
      SetTextForControl(IDC_AI_RUN, L"润色");
      break;
    case Mode::Asr:
      SetTextForControl(IDC_AI_LABEL_RESULT, L"转写结果");
      SetTextForControl(IDC_AI_RUN, L"转写");
      break;
  }

  const bool can_run = m_service &&
                       ((mode == Mode::Chat && m_service->IsChatAvailable()) ||
                        (mode == Mode::Polish &&
                         m_service->IsRewriteAvailable()) ||
                        (mode == Mode::Asr && m_service->IsAsrAvailable()));
  m_run_button.EnableWindow(can_run);
  if (m_service && m_status_tone == StatusTone::Neutral) {
    SetStatusText(m_service->GetAvailabilityHint());
  }
  LayoutControls();
  UpdateRoundedRegions();
  Invalidate();
}

void AIAssistantDialog::ApplyWindowChrome() {
  ModifyStyle(WS_CAPTION | DS_MODALFRAME, WS_THICKFRAME | WS_CLIPCHILDREN);
  ModifyStyleEx(WS_EX_DLGMODALFRAME, 0);

  BOOL dark_mode = FALSE;
  ::DwmSetWindowAttribute(m_hWnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark_mode,
                          sizeof(dark_mode));
  const DWM_WINDOW_CORNER_PREFERENCE corner_preference =
      DWMWCP_ROUND;
  ::DwmSetWindowAttribute(m_hWnd, DWMWA_WINDOW_CORNER_PREFERENCE,
                          &corner_preference, sizeof(corner_preference));
}

void AIAssistantDialog::ApplyControlStyling() {
  auto set_flat_button = [](CButton& button) {
    button.ModifyStyle(0, BS_OWNERDRAW);
  };

  set_flat_button(m_browse_button);
  set_flat_button(m_run_button);
  set_flat_button(m_copy_button);
  set_flat_button(m_clear_button);
  set_flat_button(m_close_button);

  const DWORD edit_style =
      WS_BORDER | ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN | WS_VSCROLL;
  m_history_edit.ModifyStyle(WS_BORDER, 0);
  m_input_edit.ModifyStyle(WS_BORDER, 0);
  m_result_edit.ModifyStyle(WS_BORDER, 0);
  m_file_path_edit.ModifyStyle(WS_BORDER, 0);
  m_history_edit.SetMargins(Scale(10), Scale(10));
  m_input_edit.SetMargins(Scale(10), Scale(10));
  m_result_edit.SetMargins(Scale(10), Scale(10));
  m_file_path_edit.SetMargins(Scale(10), Scale(10));
}

void AIAssistantDialog::LayoutControls() {
  if (!::IsWindow(m_hWnd)) {
    return;
  }

  RECT client = {};
  GetClientRect(&client);
  const int pad = Scale(16);
  const int shell_left = pad;
  const int shell_top = pad;
  const int shell_width = client.right - pad * 2;
  const int shell_height = client.bottom - pad * 2;
  const int inner_pad = Scale(22);
  const int gutter = Scale(12);
  const int header_height = Scale(74);
  const int footer_height = Scale(76);
  const int mode_w = Scale(132);
  const int tone_w = Scale(132);
  const int close_size = Scale(34);
  const int label_h = Scale(20);
  const int edit_h_small = Scale(38);
  const int button_h = Scale(38);
  const int action_button_w = Scale(96);
  const int browse_w = Scale(82);

  const int content_left = shell_left + inner_pad;
  const int content_right = shell_left + shell_width - inner_pad;
  const int header_bottom = shell_top + header_height;
  const int footer_top = shell_top + shell_height - footer_height;
  const int content_top = header_bottom + Scale(16);
  const int content_bottom = footer_top - Scale(16);
  const int content_width = content_right - content_left;

  MoveControl(IDC_AI_MODE, content_right - close_size - gutter - tone_w - gutter -
                              mode_w,
              shell_top + Scale(18), mode_w, edit_h_small);
  MoveControl(IDC_AI_TONE, content_right - close_size - gutter - tone_w,
              shell_top + Scale(18), tone_w, edit_h_small);
  MoveControl(IDC_AI_CLOSE, content_right - close_size, shell_top + Scale(18),
              close_size, close_size);

  const bool show_history = GetCurrentMode() == Mode::Chat;
  const bool show_input =
      GetCurrentMode() == Mode::Chat || GetCurrentMode() == Mode::Polish;
  const bool show_file = GetCurrentMode() == Mode::Asr;
  const bool show_tone = GetCurrentMode() == Mode::Polish;

  int cursor_y = content_top;

  if (show_file) {
    MoveControl(IDC_AI_LABEL_FILE, content_left, cursor_y, content_width, label_h);
    cursor_y += label_h + Scale(6);
    MoveControl(IDC_AI_FILEPATH, content_left, cursor_y,
                content_width - browse_w - gutter, edit_h_small);
    MoveControl(IDC_AI_BROWSE, content_right - browse_w, cursor_y, browse_w,
                edit_h_small);
    cursor_y += edit_h_small + Scale(16);
  }

  if (show_history) {
    MoveControl(IDC_AI_LABEL_HISTORY, content_left, cursor_y, content_width,
                label_h);
    cursor_y += label_h + Scale(6);
    const int history_height = Scale(110);
    MoveControl(IDC_AI_HISTORY, content_left, cursor_y, content_width,
                history_height);
    cursor_y += history_height + Scale(14);
  }

  if (show_input) {
    MoveControl(IDC_AI_LABEL_INPUT, content_left, cursor_y, content_width, label_h);
    cursor_y += label_h + Scale(6);
    const int input_height =
        GetCurrentMode() == Mode::Chat ? Scale(86) : Scale(108);
    MoveControl(IDC_AI_INPUT, content_left, cursor_y, content_width, input_height);
    cursor_y += input_height + Scale(14);
  }

  if (show_tone) {
    MoveControl(IDC_AI_LABEL_TONE, content_left, cursor_y, content_width, label_h);
    cursor_y += label_h + Scale(6);
    MoveControl(IDC_AI_TONE, content_left, cursor_y, Scale(180), edit_h_small);
    cursor_y += edit_h_small + Scale(14);
  }

  MoveControl(IDC_AI_LABEL_RESULT, content_left, cursor_y, content_width, label_h);
  cursor_y += label_h + Scale(6);
  const int result_height = (std::max)(Scale(92), content_bottom - cursor_y);
  MoveControl(IDC_AI_RESULT, content_left, cursor_y, content_width, result_height);

  const int footer_y = footer_top + Scale(18);
  MoveControl(IDC_AI_STATUS, content_left, footer_y + Scale(4),
              content_width - action_button_w * 3 - gutter * 2 - Scale(24),
              Scale(28));
  MoveControl(IDC_AI_RUN,
              content_right - action_button_w * 3 - gutter * 2, footer_y,
              action_button_w, button_h);
  MoveControl(IDC_AI_COPY,
              content_right - action_button_w * 2 - gutter, footer_y,
              action_button_w, button_h);
  MoveControl(IDC_AI_CLEAR, content_right - action_button_w, footer_y,
              action_button_w, button_h);
}

void AIAssistantDialog::RefreshFonts() {
  if (m_title_font) {
    ::DeleteObject(m_title_font);
    m_title_font = nullptr;
  }
  if (m_subtitle_font) {
    ::DeleteObject(m_subtitle_font);
    m_subtitle_font = nullptr;
  }
  if (m_button_font) {
    ::DeleteObject(m_button_font);
    m_button_font = nullptr;
  }
  if (m_window_brush) {
    ::DeleteObject(m_window_brush);
  }
  if (m_surface_brush) {
    ::DeleteObject(m_surface_brush);
  }
  if (m_readonly_surface_brush) {
    ::DeleteObject(m_readonly_surface_brush);
  }

  LOGFONTW title_font = BuildUiFont(16, FW_SEMIBOLD, L"Segoe UI");
  LOGFONTW subtitle_font = BuildUiFont(9, FW_NORMAL, L"Segoe UI");
  LOGFONTW button_font = BuildUiFont(10, FW_SEMIBOLD, L"Segoe UI");

  m_title_font = ::CreateFontIndirectW(&title_font);
  m_subtitle_font = ::CreateFontIndirectW(&subtitle_font);
  m_button_font = ::CreateFontIndirectW(&button_font);
  m_window_brush = ::CreateSolidBrush(kWindowBackground);
  m_surface_brush = ::CreateSolidBrush(kPanelBackground);
  m_readonly_surface_brush = ::CreateSolidBrush(kReadOnlyPanelBackground);

  if (m_title_font) {
    ::SendMessage(m_hWnd, WM_SETFONT, reinterpret_cast<WPARAM>(m_title_font),
                  TRUE);
  }
  const HWND controls[] = {
      m_mode_combo,   m_tone_combo,    m_history_edit, m_input_edit,
      m_result_edit,  m_file_path_edit, m_browse_button, m_run_button,
      m_copy_button,  m_clear_button,  m_close_button,
      GetDlgItem(IDC_AI_STATUS),       GetDlgItem(IDC_AI_LABEL_HISTORY),
      GetDlgItem(IDC_AI_LABEL_INPUT),  GetDlgItem(IDC_AI_LABEL_RESULT),
      GetDlgItem(IDC_AI_LABEL_FILE),   GetDlgItem(IDC_AI_LABEL_TONE)};

  for (HWND hwnd : controls) {
    if (::IsWindow(hwnd)) {
      ::SendMessage(hwnd, WM_SETFONT, reinterpret_cast<WPARAM>(m_button_font),
                    TRUE);
    }
  }
}

void AIAssistantDialog::RefreshConversationHistory() {
  std::wstring history_text;
  for (const auto& turn : m_conversation_history) {
    history_text += (turn.role == L"assistant") ? L"AI\n" : L"你\n";
    history_text += turn.text;
    history_text += L"\r\n\r\n";
  }
  m_history_edit.SetWindowTextW(history_text.c_str());
}

void AIAssistantDialog::SetStatusText(const std::wstring& text) {
  SetTextForControl(IDC_AI_STATUS, text);
  InvalidateRect(&GetControlRect(IDC_AI_STATUS), FALSE);
}

void AIAssistantDialog::SetResultText(const std::wstring& text) {
  m_result_edit.SetWindowTextW(text.c_str());
}

std::wstring AIAssistantDialog::GetTextFromEdit(CEdit& edit) const {
  const int length = edit.GetWindowTextLengthW();
  std::vector<wchar_t> buffer(static_cast<size_t>(length) + 1, L'\0');
  edit.GetWindowTextW(buffer.data(), length + 1);
  return std::wstring(buffer.data());
}

void AIAssistantDialog::SetTextForControl(int control_id,
                                          const std::wstring& text) {
  ::SetWindowTextW(GetDlgItem(control_id), text.c_str());
}

void AIAssistantDialog::ShowControl(int control_id, bool visible) {
  ::ShowWindow(GetDlgItem(control_id), visible ? SW_SHOW : SW_HIDE);
}

void AIAssistantDialog::MoveControl(int control_id, int x, int y, int width,
                                    int height) {
  HWND hwnd = GetDlgItem(control_id);
  if (::IsWindow(hwnd)) {
    ::SetWindowPos(hwnd, nullptr, x, y, width, height,
                   SWP_NOZORDER | SWP_NOACTIVATE);
  }
}

void AIAssistantDialog::ApplyRoundedRegion(HWND hwnd, int radius) {
  if (!::IsWindow(hwnd)) {
    return;
  }
  RECT rect = {};
  ::GetWindowRect(hwnd, &rect);
  const int width = rect.right - rect.left;
  const int height = rect.bottom - rect.top;
  HRGN region = ::CreateRoundRectRgn(0, 0, width + 1, height + 1, radius,
                                     radius);
  ::SetWindowRgn(hwnd, region, TRUE);
}

void AIAssistantDialog::UpdateRoundedRegions() {
  ApplyRoundedRegion(m_hWnd, Scale(kWindowCornerRadius));
  ApplyRoundedRegion(m_history_edit, Scale(kEditRadius));
  ApplyRoundedRegion(m_input_edit, Scale(kEditRadius));
  ApplyRoundedRegion(m_result_edit, Scale(kEditRadius));
  ApplyRoundedRegion(m_file_path_edit, Scale(kEditRadius));
}

AIAssistantDialog::Mode AIAssistantDialog::GetCurrentMode() const {
  switch (m_mode_combo.GetCurSel()) {
    case 1:
      return Mode::Polish;
    case 2:
      return Mode::Asr;
    case 0:
    default:
      return Mode::Chat;
  }
}

AIAssistantService::TonePreset AIAssistantDialog::GetSelectedTone() const {
  switch (m_tone_combo.GetCurSel()) {
    case 1:
      return AIAssistantService::TonePreset::Formal;
    case 2:
      return AIAssistantService::TonePreset::Rigorous;
    case 3:
      return AIAssistantService::TonePreset::Playful;
    case 0:
    default:
      return AIAssistantService::TonePreset::Cute;
  }
}

bool AIAssistantDialog::CopyTextToClipboard(const std::wstring& text) const {
  if (!::OpenClipboard(m_hWnd)) {
    return false;
  }
  ::EmptyClipboard();
  const size_t bytes = (text.size() + 1) * sizeof(wchar_t);
  HGLOBAL clipboard_data = ::GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (!clipboard_data) {
    ::CloseClipboard();
    return false;
  }

  void* target = ::GlobalLock(clipboard_data);
  memcpy(target, text.c_str(), bytes);
  ::GlobalUnlock(clipboard_data);
  if (!::SetClipboardData(CF_UNICODETEXT, clipboard_data)) {
    ::GlobalFree(clipboard_data);
    ::CloseClipboard();
    return false;
  }
  ::CloseClipboard();
  return true;
}

UINT AIAssistantDialog::GetCurrentDpi() const {
  if (m_visual_dpi != 0) {
    return m_visual_dpi;
  }
  return 96;
}

int AIAssistantDialog::Scale(int value) const {
  return MulDiv(value, static_cast<int>(GetCurrentDpi()), 96);
}

RECT AIAssistantDialog::GetControlRect(int control_id) const {
  RECT rect = {};
  HWND hwnd = GetDlgItem(control_id);
  if (!::IsWindow(hwnd)) {
    return rect;
  }
  ::GetWindowRect(hwnd, &rect);
  ::MapWindowPoints(nullptr, m_hWnd, reinterpret_cast<LPPOINT>(&rect), 2);
  return rect;
}

COLORREF AIAssistantDialog::GetAccentColor() const {
  return kAccentPrimary;
}

COLORREF AIAssistantDialog::GetStatusColor() const {
  switch (m_status_tone) {
    case StatusTone::Success:
      return kSuccessColor;
    case StatusTone::Error:
      return kErrorColor;
    case StatusTone::Neutral:
    default:
      return kTextSecondary;
  }
}

void AIAssistantDialog::DrawRoundedBlock(HDC hdc,
                                         const RECT& rect,
                                         COLORREF fill_color,
                                         COLORREF border_color,
                                         int radius) const {
  HBRUSH fill = ::CreateSolidBrush(fill_color);
  HPEN border = ::CreatePen(PS_SOLID, 1, border_color);
  HGDIOBJ old_brush = ::SelectObject(hdc, fill);
  HGDIOBJ old_pen = ::SelectObject(hdc, border);
  ::RoundRect(hdc, rect.left, rect.top, rect.right, rect.bottom, radius, radius);
  ::SelectObject(hdc, old_pen);
  ::SelectObject(hdc, old_brush);
  ::DeleteObject(border);
  ::DeleteObject(fill);
}
