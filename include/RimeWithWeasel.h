#pragma once
#include <WeaselIPC.h>
#include <WeaselUI.h>
#include <map>
#include <string>
#include <thread>
#include <memory>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <vector>

#include <rime_api.h>
#include "../WeaselServer/LLMProvider.h"

// 前向声明
class ContextHistory;
class DevConsole;
class LLMTaskScheduler;

class ScopedThread {
 public:
  template <typename Function>
  ScopedThread(Function&& f) : thread(std::forward<Function>(f)) {}
  ~ScopedThread() {
    if (thread.joinable())
      thread.join();
  }
  ScopedThread(const ScopedThread&) = delete;
  ScopedThread& operator=(const ScopedThread&) = delete;

 private:
  std::thread thread;
};

struct CaseInsensitiveCompare {
  bool operator()(const std::string& str1, const std::string& str2) const {
    std::string str1Lower, str2Lower;
    std::transform(str1.begin(), str1.end(), std::back_inserter(str1Lower),
                   [](char c) { return std::tolower(c); });
    std::transform(str2.begin(), str2.end(), std::back_inserter(str2Lower),
                   [](char c) { return std::tolower(c); });
    return str1Lower < str2Lower;
  }
};

typedef std::map<std::string, bool> AppOptions;
typedef std::map<std::string, AppOptions, CaseInsensitiveCompare>
    AppOptionsByAppName;

struct SessionStatus {
  SessionStatus() : style(weasel::UIStyle()), __synced(false), session_id(0) {
    RIME_STRUCT(RimeStatus, status);
  }
  weasel::UIStyle style;
  RimeStatus status;
  bool __synced;
  RimeSessionId session_id;
};
typedef std::map<DWORD, SessionStatus> SessionStatusMap;
typedef DWORD WeaselSessionId;
class RimeWithWeaselHandler : public weasel::RequestHandler {
 public:
  RimeWithWeaselHandler(weasel::UI* ui);
  virtual ~RimeWithWeaselHandler();
  virtual void Initialize();
  virtual void Finalize();
  virtual DWORD FindSession(WeaselSessionId ipc_id);
  virtual DWORD AddSession(LPWSTR buffer, EatLine eat = 0);
  virtual DWORD RemoveSession(WeaselSessionId ipc_id);
  virtual BOOL ProcessKeyEvent(weasel::KeyEvent keyEvent,
                               WeaselSessionId ipc_id,
                               EatLine eat);
  virtual void CommitComposition(WeaselSessionId ipc_id);
  virtual void ClearComposition(WeaselSessionId ipc_id);
  virtual void SelectCandidateOnCurrentPage(size_t index,
                                            WeaselSessionId ipc_id);
  virtual bool HighlightCandidateOnCurrentPage(size_t index,
                                               WeaselSessionId ipc_id,
                                               EatLine eat);
  virtual bool ChangePage(bool backward, WeaselSessionId ipc_id, EatLine eat);
  virtual void FocusIn(DWORD param, WeaselSessionId ipc_id);
  virtual void FocusOut(DWORD param, WeaselSessionId ipc_id);
  virtual void UpdateInputPosition(RECT const& rc, WeaselSessionId ipc_id);
  virtual void StartMaintenance();
  virtual void EndMaintenance();
  virtual void SetOption(WeaselSessionId ipc_id,
                         const std::string& opt,
                         bool val);
  virtual void UpdateColorTheme(BOOL darkMode);

  void OnUpdateUI(std::function<void()> const& cb);

  // 设置上下文历史记录实例
  void SetContextHistory(ContextHistory* context_history);

  // 设置开发终端实例
  void SetDevConsole(DevConsole* dev_console);

  // 获取上下文历史记录（供LLM使用）
  ContextHistory* GetContextHistory() const { return m_context_history; }

 private:
  struct DisplayCandidate {
    enum class Source { Rime, LLM, PendingPlaceholder };

    Source source;
    size_t index;
    bool matched_by_llm;
  };

  struct LLMCandidateSnapshot {
    std::vector<std::wstring> candidates;
    std::vector<std::wstring> rerank_candidates;
    std::vector<size_t> rerank_indices;
    std::wstring provider_name;
    bool require_rime_candidates;
    bool enable_rime_reorder;
    bool prefer_llm_primary;
    bool from_no_input;
    bool input_translation_pending;
    bool async_ui_pending;
    uint64_t rerank_ui_update_not_before;
  };

  void _Setup();
  bool _IsDeployerRunning();
  void _UpdateUI(WeaselSessionId ipc_id);
  void _LoadSchemaSpecificSettings(WeaselSessionId ipc_id,
                                   const std::string& schema_id);
  void _LoadAppInlinePreeditSet(WeaselSessionId ipc_id,
                                bool ignore_app_name = false);
  bool _ShowMessage(weasel::Context& ctx, weasel::Status& status);
  bool _Respond(WeaselSessionId ipc_id, EatLine eat);
  void _ReadClientInfo(WeaselSessionId ipc_id, LPWSTR buffer);
  void _GetCandidateInfo(weasel::CandidateInfo& cinfo, RimeContext& ctx);
  void _GetCandidateInfo(weasel::CandidateInfo& cinfo,
                         RimeContext& ctx,
                         const LLMCandidateSnapshot& llm_snapshot);
  void _GetStatus(weasel::Status& stat,
                  WeaselSessionId ipc_id,
                  weasel::Context& ctx);
  void _GetStatus(weasel::Status& stat,
                  WeaselSessionId ipc_id,
                  weasel::Context& ctx,
                  const LLMCandidateSnapshot& llm_snapshot);
  void _GetContext(weasel::Context& ctx, RimeSessionId session_id);
  void _GetContext(weasel::Context& ctx,
                   RimeSessionId session_id,
                   const LLMCandidateSnapshot& llm_snapshot);
  void _UpdateShowNotifications(RimeConfig* config, bool initialize = false);
  std::wstring _TrimPredictionContext(const std::wstring& context) const;
  LLMCandidateSnapshot _SnapshotLLMCandidates();
  bool _HasLLMDisplayCandidates(const LLMCandidateSnapshot& llm_snapshot) const;
  bool _HasAsyncUIUpdatePending(const LLMCandidateSnapshot& llm_snapshot) const;
  void _MarkAsyncUIUpdatePending(uint64_t request_seq);
  void _ClearAsyncUIUpdatePending(uint64_t request_seq = 0);
  std::vector<DisplayCandidate> _BuildDisplayCandidates(
      const RimeContext* ctx,
      const LLMCandidateSnapshot& llm_snapshot);
  std::wstring _GetDisplayLabel(const RimeContext& ctx, size_t display_index);
  bool _TryResolveDisplaySelectionIndex(const weasel::KeyEvent& key_event,
                                        const RimeContext& ctx,
                                        size_t display_candidate_count,
                                        size_t& display_index);
  bool _SelectDisplayCandidate(const DisplayCandidate& candidate,
                               const std::vector<std::wstring>& llm_candidates,
                               WeaselSessionId ipc_id,
                               EatLine eat);
  bool _TryScheduleLLMForCurrentComposition(WeaselSessionId ipc_id,
                                            RimeSessionId session_id,
                                            DWORD event_time,
                                            bool triggered_by_grave_key);
  void _ClearLLMResultsForInputChange(bool clear_rerank_results = true);
  void _ClearContextHistory(const std::wstring& reason);
  void _NoteUserActivity();
  void _ArmNoInputPredictionAutoHide(WeaselSessionId ipc_id);
  void _EnsureLLMTaskScheduler();
  void _ShutdownLLMTaskScheduler();

  bool _IsSessionTSF(RimeSessionId session_id);
  void _UpdateInlinePreeditStatus(WeaselSessionId ipc_id);

  RimeSessionId to_session_id(WeaselSessionId ipc_id) {
    return m_session_status_map[ipc_id].session_id;
  }
  SessionStatus& get_session_status(WeaselSessionId ipc_id) {
    return m_session_status_map[ipc_id];
  }
  SessionStatus& new_session_status(WeaselSessionId ipc_id) {
    return m_session_status_map[ipc_id] = SessionStatus();
  }

  AppOptionsByAppName m_app_options;
  weasel::UI* m_ui;  // reference
  DWORD m_active_session;
  bool m_disabled;
  std::string m_last_schema_id;
  std::string m_last_app_name;
  weasel::UIStyle m_base_style;
  std::map<std::string, bool> m_show_notifications;
  std::map<std::string, bool> m_show_notifications_base;
  std::function<void()> _UpdateUICallback;
  bool m_tsf_exclusive_candidate_window;
  bool m_log_candidate_window_routing;

  static void OnNotify(void* context_object,
                       uintptr_t session_id,
                       const char* message_type,
                       const char* message_value);
  static std::string m_message_type;
  static std::string m_message_value;
  static std::string m_message_label;
  static std::string m_option_name;
  SessionStatusMap m_session_status_map;
  bool m_current_dark_mode;
  bool m_global_ascii_mode;
  int m_show_notifications_time;
  DWORD m_pid;

  // 上下文历史记录和开发终端
  ContextHistory* m_context_history;
  DevConsole* m_dev_console;
  std::unique_ptr<LLMTaskScheduler> m_llm_task_scheduler;

  // LLM相关（上下文统一从 m_context_history 获取，不再单独维护 buffer）
  std::unique_ptr<LLMProvider> m_llm_provider;  // 无拼音预测
  std::unique_ptr<LLMProvider>
      m_pinyin_translation_provider;  // 有拼音异步翻译补充候选
  std::unique_ptr<LLMProvider> m_pinyin_rerank_provider;  // 有拼音实时重排
  bool m_llm_prediction_mode;
  std::vector<std::wstring> m_current_llm_candidates;
  std::vector<std::wstring> m_current_llm_rerank_candidates;
  std::vector<size_t> m_current_llm_rerank_indices;
  std::wstring m_current_llm_candidate_provider_name;
  uint64_t m_current_llm_rerank_ui_update_not_before;
  std::wstring m_pending_llm_commit;  // 待提交的LLM候选词
  std::atomic<uint64_t> m_llm_request_seq{
      0};  // LLM异步预测请求序号（用于丢弃旧结果）
  std::atomic<uint64_t> m_llm_user_activity_seq{
      0};  // 用户交互序号（用于无输入预测超时）
  std::atomic<uint64_t> m_llm_no_input_hide_seq{0};  // 无输入预测自动隐藏序号
  std::atomic<uint64_t> m_llm_async_ui_pending_seq{
      0};                  // 当前仍可能触发 UI 变化的异步请求序号
  std::mutex m_llm_mutex;  // 保护 m_current_llm_candidates
  bool m_current_llm_candidates_require_rime;
  bool m_current_llm_candidates_enable_rime_reorder;
  bool m_current_llm_candidates_prefer_primary;
  bool m_current_llm_candidates_from_no_input;
  bool m_current_llm_input_translation_pending;
  bool m_llm_developer_mode;
  bool m_llm_show_source_labels;
  bool m_llm_enable_pinyin_constraint;
  size_t m_llm_context_recent_words;
  size_t m_llm_context_max_chars;
  DWORD m_llm_input_prediction_debounce_ms;
  DWORD m_llm_rerank_suppressed_until;  // 连续编辑后禁止 rerank 的截止时间
  DWORD m_last_edit_key_time;           // 上次编辑键时间
  size_t m_consecutive_edit_key_count;  // 连续编辑键次数
  bool m_has_display_highlight_override;
  size_t m_display_highlight_override;

  // 双击·键检测（用于清空上下文）
  DWORD m_last_grave_key_time;  // 上次·键按下的时间（毫秒）
  static const DWORD GRAVE_DOUBLE_CLICK_TIMEOUT =
      500;  // 双击时间间隔阈值（毫秒）
  static const DWORD LLM_INPUT_IDLE_TRIGGER_MS =
      200;  // 新增拼音后需静默 200 ms，才触发有拼音 AI
  static const DWORD LLM_NO_INPUT_AUTO_HIDE_MS =
      10000;  // 无输入预测 10 秒无操作后自动隐藏
  static const DWORD LLM_RERANK_SUPPRESS_MS = 800;    // 连续编辑后抑制重排时长
  static const DWORD LLM_EDIT_BURST_WINDOW_MS = 150;  // 识别连续编辑的时间窗口
  static const size_t LLM_EDIT_BURST_THRESHOLD = 3;   // 连续编辑触发抑制阈值

  // LLM预测相关方法
  void _TriggerLLMPrediction(
      WeaselSessionId ipc_id,
      LLMRequestType request_type = LLMRequestType::NoInputPrediction,
      const std::wstring& current_input = L"",
      bool require_rime_candidates = false,
      DWORD debounce_ms = 0,
      uint64_t ui_update_not_before = 0);
  void _ExitLLMPredictionMode(WeaselSessionId ipc_id,
                              bool refresh_ui_immediately = true);
};
