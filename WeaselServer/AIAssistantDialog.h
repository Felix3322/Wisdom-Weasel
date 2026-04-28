#pragma once

#include "AIAssistantService.h"
#include "resource.h"
#include <CDialogDpiAware.h>

class AIAssistantDialog : public CDialogDpiAware<AIAssistantDialog> {
 public:
  enum { IDD = IDD_AI_ASSISTANT };

  explicit AIAssistantDialog(AIAssistantService* service);
  ~AIAssistantDialog();
  void SetInitialModeIndex(int mode_index);

 protected:
  BEGIN_MSG_MAP(AIAssistantDialog)
  CHAIN_MSG_MAP(CDialogDpiAware<AIAssistantDialog>)
  MESSAGE_HANDLER(WM_INITDIALOG, OnInitDialog)
  MESSAGE_HANDLER(WM_CLOSE, OnClose)
  MESSAGE_HANDLER(WM_DESTROY, OnDestroy)
  MESSAGE_HANDLER(WM_ERASEBKGND, OnEraseBackground)
  MESSAGE_HANDLER(WM_PAINT, OnPaint)
  MESSAGE_HANDLER(WM_SIZE, OnSize)
  MESSAGE_HANDLER(WM_NCHITTEST, OnNcHitTest)
  MESSAGE_HANDLER(WM_CTLCOLORDLG, OnCtlColorDialog)
  MESSAGE_HANDLER(WM_CTLCOLORSTATIC, OnCtlColorStatic)
  MESSAGE_HANDLER(WM_CTLCOLOREDIT, OnCtlColorEdit)
  MESSAGE_HANDLER(WM_CTLCOLORBTN, OnCtlColorButton)
  MESSAGE_HANDLER(WM_DRAWITEM, OnDrawItem)
  COMMAND_ID_HANDLER(IDOK, OnRun)
  COMMAND_ID_HANDLER(IDCANCEL, OnCloseCommand)
  COMMAND_ID_HANDLER(IDC_AI_CLOSE, OnCloseCommand)
  COMMAND_ID_HANDLER(IDC_AI_BROWSE, OnBrowseAudio)
  COMMAND_ID_HANDLER(IDC_AI_RUN, OnRun)
  COMMAND_ID_HANDLER(IDC_AI_COPY, OnCopyResult)
  COMMAND_ID_HANDLER(IDC_AI_CLEAR, OnClear)
  COMMAND_HANDLER(IDC_AI_MODE, CBN_SELCHANGE, OnModeChanged)
  END_MSG_MAP()

 private:
  enum class Mode {
    Chat = 0,
    Polish = 1,
    Asr = 2,
  };

  LRESULT OnInitDialog(UINT, WPARAM, LPARAM, BOOL&);
  LRESULT OnClose(UINT, WPARAM, LPARAM, BOOL&);
  LRESULT OnDestroy(UINT, WPARAM, LPARAM, BOOL&);
  LRESULT OnCloseCommand(WORD, WORD code, HWND, BOOL&);
  LRESULT OnRun(WORD, WORD code, HWND, BOOL&);
  LRESULT OnBrowseAudio(WORD, WORD code, HWND, BOOL&);
  LRESULT OnCopyResult(WORD, WORD code, HWND, BOOL&);
  LRESULT OnClear(WORD, WORD code, HWND, BOOL&);
  LRESULT OnModeChanged(WORD, WORD code, HWND, BOOL&);
  LRESULT OnEraseBackground(UINT, WPARAM, LPARAM, BOOL&);
  LRESULT OnPaint(UINT, WPARAM, LPARAM, BOOL&);
  LRESULT OnSize(UINT, WPARAM, LPARAM, BOOL&);
  LRESULT OnNcHitTest(UINT, WPARAM, LPARAM, BOOL&);
  LRESULT OnCtlColorDialog(UINT, WPARAM, LPARAM, BOOL&);
  LRESULT OnCtlColorStatic(UINT, WPARAM, LPARAM, BOOL&);
  LRESULT OnCtlColorEdit(UINT, WPARAM, LPARAM, BOOL&);
  LRESULT OnCtlColorButton(UINT, WPARAM, LPARAM, BOOL&);
  LRESULT OnDrawItem(UINT, WPARAM, LPARAM, BOOL&);

  void ApplyModeUI();
  void ApplyWindowChrome();
  void ApplyControlStyling();
  void LayoutControls();
  void RefreshFonts();
  void RefreshConversationHistory();
  void SetStatusText(const std::wstring& text);
  void SetResultText(const std::wstring& text);
  std::wstring GetTextFromEdit(CEdit& edit) const;
  void SetTextForControl(int control_id, const std::wstring& text);
  void ShowControl(int control_id, bool visible);
  void MoveControl(int control_id, int x, int y, int width, int height);
  void ApplyRoundedRegion(HWND hwnd, int radius);
  void UpdateRoundedRegions();
  Mode GetCurrentMode() const;
  AIAssistantService::TonePreset GetSelectedTone() const;
  bool CopyTextToClipboard(const std::wstring& text) const;
  UINT GetCurrentDpi() const;
  int Scale(int value) const;
  RECT GetControlRect(int control_id) const;
  COLORREF GetAccentColor() const;
  COLORREF GetStatusColor() const;
  void DrawRoundedBlock(HDC hdc,
                        const RECT& rect,
                        COLORREF fill_color,
                        COLORREF border_color,
                        int radius) const;

 private:
  enum class StatusTone {
    Neutral = 0,
    Success = 1,
    Error = 2,
  };

  AIAssistantService* m_service;
  std::vector<AIAssistantService::ConversationTurn> m_conversation_history;
  int m_initial_mode_index = 0;
  StatusTone m_status_tone = StatusTone::Neutral;
  UINT m_visual_dpi = 0;

  CComboBox m_mode_combo;
  CComboBox m_tone_combo;
  CEdit m_history_edit;
  CEdit m_input_edit;
  CEdit m_result_edit;
  CEdit m_file_path_edit;
  CButton m_browse_button;
  CButton m_run_button;
  CButton m_copy_button;
  CButton m_clear_button;
  CButton m_close_button;

  HFONT m_title_font = nullptr;
  HFONT m_subtitle_font = nullptr;
  HFONT m_button_font = nullptr;
  HBRUSH m_window_brush = nullptr;
  HBRUSH m_surface_brush = nullptr;
  HBRUSH m_readonly_surface_brush = nullptr;
};
