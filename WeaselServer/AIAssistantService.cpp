#include "stdafx.h"
#include "AuditLogger.h"
#include "AIAssistantService.h"

#include "ConfigJsonUtils.h"
#include <WeaselUtility.h>
#include <boost/property_tree/json_parser.hpp>
#include <boost/property_tree/ptree.hpp>
#include <rime_api.h>
#include <winhttp.h>

#include <algorithm>
#include <cctype>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <locale>
#include <sstream>

#pragma comment(lib, "winhttp.lib")

namespace {

constexpr int kDefaultChatTimeoutMs = 30000;
constexpr int kDefaultAsrTimeoutMs = 120000;
constexpr int kMaxConversationTurns = 12;

std::wstring TrimWhitespace(std::wstring text) {
  auto not_space = [](wchar_t ch) { return !iswspace(ch); };
  text.erase(text.begin(), std::find_if(text.begin(), text.end(), not_space));
  text.erase(std::find_if(text.rbegin(), text.rend(), not_space).base(),
             text.end());
  return text;
}

bool EndsWithInsensitive(const std::string& value, const std::string& suffix) {
  if (value.size() < suffix.size()) {
    return false;
  }
  const size_t start = value.size() - suffix.size();
  for (size_t i = 0; i < suffix.size(); ++i) {
    if (std::tolower(static_cast<unsigned char>(value[start + i])) !=
        std::tolower(static_cast<unsigned char>(suffix[i]))) {
      return false;
    }
  }
  return true;
}

std::string ReplaceTrailingPath(const std::string& value,
                                const std::string& suffix,
                                const std::string& replacement) {
  if (!EndsWithInsensitive(value, suffix)) {
    return value;
  }
  return value.substr(0, value.size() - suffix.size()) + replacement;
}

bool IsLocalOllamaUrl(const std::string& url) {
  return url.find("127.0.0.1:11434") != std::string::npos ||
         url.find("localhost:11434") != std::string::npos;
}

bool IsLocalHostName(const std::wstring& host_name) {
  std::wstring normalized = host_name;
  std::transform(normalized.begin(), normalized.end(), normalized.begin(),
                 [](wchar_t ch) { return static_cast<wchar_t>(towlower(ch)); });
  return normalized == L"localhost" || normalized == L"127.0.0.1" ||
         normalized == L"::1";
}

std::string DeriveTranscriptionUrl(const std::string& chat_url) {
  if (IsLocalOllamaUrl(chat_url)) {
    return "http://127.0.0.1:8013/v1/transcribe";
  }
  std::string url = ReplaceTrailingPath(chat_url, "/chat/completions",
                                        "/audio/transcriptions");
  if (url != chat_url) {
    return url;
  }
  url =
      ReplaceTrailingPath(chat_url, "/v1/responses", "/v1/audio/transcriptions");
  if (url != chat_url) {
    return url;
  }
  if (!url.empty() && url.back() == '/') {
    url.pop_back();
  }
  return url + "/audio/transcriptions";
}

bool TryGetConfigStringWithFallback(RimeApi* api,
                                    RimeConfig* config,
                                    const std::string& primary_path,
                                    const std::string& fallback_path,
                                    std::string& value) {
  return weasel::config_json::TryGetConfigStringValue(api, config, primary_path,
                                                      value) ||
         (!fallback_path.empty() &&
          weasel::config_json::TryGetConfigStringValue(api, config,
                                                       fallback_path, value));
}

bool TryGetConfigIntWithFallback(RimeApi* api,
                                 RimeConfig* config,
                                 const std::string& primary_path,
                                 const std::string& fallback_path,
                                 int& value) {
  if (api->config_get_int &&
      api->config_get_int(config, primary_path.c_str(), &value)) {
    return true;
  }
  return !fallback_path.empty() && api->config_get_int &&
         api->config_get_int(config, fallback_path.c_str(), &value);
}

bool TryGetConfigBoolWithFallback(RimeApi* api,
                                  RimeConfig* config,
                                  const std::string& primary_path,
                                  const std::string& fallback_path,
                                  bool& value) {
  Bool bool_value = false;
  if (api->config_get_bool &&
      api->config_get_bool(config, primary_path.c_str(), &bool_value)) {
    value = !!bool_value;
    return true;
  }
  if (!fallback_path.empty() && api->config_get_bool &&
      api->config_get_bool(config, fallback_path.c_str(), &bool_value)) {
    value = !!bool_value;
    return true;
  }
  return false;
}

bool TryGetConfigDoubleWithFallback(RimeApi* api,
                                    RimeConfig* config,
                                    const std::string& primary_path,
                                    const std::string& fallback_path,
                                    double& value) {
  if (api->config_get_double &&
      api->config_get_double(config, primary_path.c_str(), &value)) {
    return true;
  }

  std::string raw_value;
  if (TryGetConfigStringWithFallback(api, config, primary_path, fallback_path,
                                     raw_value)) {
    try {
      value = std::stod(raw_value);
      return true;
    } catch (...) {
      return false;
    }
  }
  return false;
}

std::wstring GetWinHttpErrorMessage(const wchar_t* stage) {
  const DWORD error_code = GetLastError();
  LPWSTR buffer = nullptr;
  const DWORD buffer_len = FormatMessageW(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
          FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, error_code, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
      reinterpret_cast<LPWSTR>(&buffer), 0, nullptr);
  std::wstring message(stage ? stage : L"WinHTTP");
  message += L"失败";
  if (buffer_len > 0 && buffer) {
    message += L"：";
    message += TrimWhitespace(buffer);
    LocalFree(buffer);
  } else {
    message += L"，错误码=" + std::to_wstring(error_code);
  }
  return message;
}

std::wstring GetMimeTypeForPath(const std::filesystem::path& path) {
  std::wstring extension = path.extension().wstring();
  std::transform(extension.begin(), extension.end(), extension.begin(),
                 [](wchar_t ch) { return static_cast<wchar_t>(towlower(ch)); });

  if (extension == L".mp3") {
    return L"audio/mpeg";
  }
  if (extension == L".wav") {
    return L"audio/wav";
  }
  if (extension == L".m4a" || extension == L".mp4") {
    return L"audio/mp4";
  }
  if (extension == L".aac") {
    return L"audio/aac";
  }
  if (extension == L".ogg") {
    return L"audio/ogg";
  }
  if (extension == L".flac") {
    return L"audio/flac";
  }
  if (extension == L".webm") {
    return L"audio/webm";
  }
  return L"application/octet-stream";
}

std::wstring ToneToInstruction(AIAssistantService::TonePreset tone) {
  switch (tone) {
    case AIAssistantService::TonePreset::Cute:
      return L"更可爱、更柔和、更有亲和力，可少量加入自然语气词，但不要幼稚化。";
    case AIAssistantService::TonePreset::Formal:
      return L"更正式、更适合公告、邮件、汇报或对外表达。";
    case AIAssistantService::TonePreset::Rigorous:
      return L"更严谨、更准确、更有条理，减少口语化和模糊表达。";
    case AIAssistantService::TonePreset::Playful:
    default:
      return L"更搞怪、更有趣、更有梗，但不要破坏原意和可读性。";
  }
}

void AppendUtf8(std::vector<uint8_t>& output, const std::string& text) {
  output.insert(output.end(), text.begin(), text.end());
}

void AppendMultipartField(std::vector<uint8_t>& output,
                          const std::string& boundary,
                          const std::string& field_name,
                          const std::string& value_utf8) {
  AppendUtf8(output, "--" + boundary + "\r\n");
  AppendUtf8(output,
             "Content-Disposition: form-data; name=\"" + field_name +
                 "\"\r\n\r\n");
  AppendUtf8(output, value_utf8);
  AppendUtf8(output, "\r\n");
}

void AppendMultipartFile(std::vector<uint8_t>& output,
                         const std::string& boundary,
                         const std::string& field_name,
                         const std::wstring& file_name,
                         const std::wstring& mime_type,
                         const std::vector<uint8_t>& file_bytes) {
  AppendUtf8(output, "--" + boundary + "\r\n");
  AppendUtf8(output,
             "Content-Disposition: form-data; name=\"" + field_name +
                 "\"; filename=\"" + wtou8(file_name) + "\"\r\n");
  AppendUtf8(output, "Content-Type: " + wtou8(mime_type) + "\r\n\r\n");
  output.insert(output.end(), file_bytes.begin(), file_bytes.end());
  AppendUtf8(output, "\r\n");
}

}  // namespace

AIAssistantService::AIAssistantService()
    : m_enabled(false),
      m_chat_temperature(0.7),
      m_chat_timeout_ms(kDefaultChatTimeoutMs),
      m_chat_system_prompt(
          L"你是 Wisdom-Weasel 的独立 AI 助手。回答要直接、实用、中文优先。"),
      m_asr_timeout_ms(kDefaultAsrTimeoutMs) {}

AIAssistantService::~AIAssistantService() = default;

bool AIAssistantService::LoadConfig(const std::string& config_name) {
  m_enabled = false;
  m_chat_api_url.clear();
  m_chat_api_key.clear();
  m_chat_model.clear();
  m_chat_temperature = 0.7;
  m_chat_timeout_ms = kDefaultChatTimeoutMs;
  m_chat_system_prompt =
      L"你是 Wisdom-Weasel 的独立 AI 助手。回答要直接、实用、中文优先。";
  m_asr_api_url.clear();
  m_asr_api_key.clear();
  m_asr_model.clear();
  m_asr_language.clear();
  m_asr_timeout_ms = kDefaultAsrTimeoutMs;
  m_availability_hint =
      L"AI 助手未配置。请在 weasel.custom.yaml 中设置 assistant/*。";
  AuditLogger::Log(L"ai_assistant",
                   L"loading config from " + u8tow(config_name));

  RimeApi* api = rime_get_api();
  if (!api) {
    m_availability_hint = L"Rime API 不可用。";
    AuditLogger::Log(L"ai_assistant", L"LoadConfig failed: Rime API unavailable");
    return false;
  }

  RimeConfig config = {0};
  if (!api->config_open(config_name.c_str(), &config)) {
    m_availability_hint =
        L"无法打开配置文件 weasel.yaml / weasel.custom.yaml。";
    AuditLogger::Log(L"ai_assistant",
                     L"LoadConfig failed: unable to open config " +
                         u8tow(config_name));
    return false;
  }

  bool enabled = false;
  if (TryGetConfigBoolWithFallback(api, &config, "assistant/enabled",
                                   "llm/enabled", enabled)) {
    m_enabled = enabled;
  }

  if (!m_enabled) {
    m_availability_hint =
        L"AI 助手未启用。请在 weasel.custom.yaml 中设置 assistant/enabled: true。";
    AuditLogger::Log(L"ai_assistant", L"LoadConfig finished: assistant disabled");
    return false;
  }

  TryGetConfigStringWithFallback(api, &config, "assistant/openai/api_url",
                                 "llm/openai/api_url", m_chat_api_url);
  if (m_chat_api_url.empty()) {
    m_chat_api_url = "https://api.openai.com/v1/chat/completions";
  }

  TryGetConfigStringWithFallback(api, &config, "assistant/openai/api_key",
                                 "llm/openai/api_key", m_chat_api_key);

  TryGetConfigStringWithFallback(api, &config, "assistant/openai/model",
                                 "llm/openai/model", m_chat_model);
  if (m_chat_model.empty()) {
    m_chat_model = "gpt-4.1-mini";
  }

  TryGetConfigDoubleWithFallback(api, &config, "assistant/openai/temperature",
                                 "llm/openai/temperature",
                                 m_chat_temperature);
  TryGetConfigIntWithFallback(api, &config, "assistant/openai/timeout_ms", "",
                              m_chat_timeout_ms);
  if (m_chat_timeout_ms <= 0) {
    m_chat_timeout_ms = kDefaultChatTimeoutMs;
  }

  std::string chat_system_prompt_utf8;
  if (weasel::config_json::TryGetConfigStringValue(
          api, &config, "assistant/chat/system_prompt",
          chat_system_prompt_utf8)) {
    m_chat_system_prompt = u8tow(chat_system_prompt_utf8);
  }

  TryGetConfigStringWithFallback(api, &config, "assistant/asr/api_url", "",
                                 m_asr_api_url);
  if (m_asr_api_url.empty()) {
    m_asr_api_url = DeriveTranscriptionUrl(m_chat_api_url);
  }

  TryGetConfigStringWithFallback(api, &config, "assistant/asr/api_key",
                                 "assistant/openai/api_key", m_asr_api_key);
  if (m_asr_api_key.empty()) {
    m_asr_api_key = m_chat_api_key;
  }

  TryGetConfigStringWithFallback(api, &config, "assistant/asr/model", "",
                                 m_asr_model);
  if (m_asr_model.empty()) {
    m_asr_model = "paraformer-zh-streaming";
  }

  weasel::config_json::TryGetConfigStringValue(api, &config,
                                               "assistant/asr/language",
                                               m_asr_language);
  TryGetConfigIntWithFallback(api, &config, "assistant/asr/timeout_ms", "",
                              m_asr_timeout_ms);
  if (m_asr_timeout_ms <= 0) {
    m_asr_timeout_ms = kDefaultAsrTimeoutMs;
  }

  if (!IsChatAvailable()) {
    m_availability_hint =
        L"AI 对话未就绪。请至少配置 assistant/openai/api_url 和 "
        L"assistant/openai/model。";
    AuditLogger::Log(L"ai_assistant",
                     L"LoadConfig failed: chat unavailable, api_url=" +
                         u8tow(m_chat_api_url) + L", model=" + u8tow(m_chat_model));
    return false;
  }

  if (!IsAsrAvailable()) {
    m_availability_hint =
        L"AI 助手已启用，但 ASR 尚未单独配置，将继续复用通用 AI 配置。";
  } else {
    m_availability_hint =
        L"AI 助手已就绪：支持 AI 对话、语气润色和音频转写。";
  }
  AuditLogger::Log(
      L"ai_assistant",
      L"LoadConfig succeeded, chat_model=" + u8tow(m_chat_model) +
          L", chat_api=" + u8tow(m_chat_api_url) + L", asr_api=" +
          u8tow(m_asr_api_url) + L", asr_model=" + u8tow(m_asr_model));
  return true;
}

bool AIAssistantService::IsChatAvailable() const {
  return m_enabled && !m_chat_api_url.empty() && !m_chat_model.empty();
}

bool AIAssistantService::IsRewriteAvailable() const {
  return IsChatAvailable();
}

bool AIAssistantService::IsAsrAvailable() const {
  return m_enabled && !m_asr_api_url.empty() && !m_asr_model.empty();
}

bool AIAssistantService::Chat(
    const std::vector<ConversationTurn>& history,
    const std::wstring& user_message,
    std::wstring& response_text,
    std::wstring& error_text) const {
  if (!IsChatAvailable()) {
    error_text = L"AI 对话未配置完成。";
    AuditLogger::Log(L"ai_assistant", L"Chat rejected: chat is not available");
    return false;
  }
  AuditLogger::Log(
      L"ai_assistant",
      L"Chat request started, history_turns=" + std::to_wstring(history.size()) +
          L", prompt_chars=" + std::to_wstring(user_message.size()));
  return RunChatLikeRequest(m_chat_system_prompt, history, user_message,
                            response_text, error_text);
}

bool AIAssistantService::Polish(const std::wstring& input_text,
                                TonePreset tone,
                                std::wstring& response_text,
                                std::wstring& error_text) const {
  if (!IsRewriteAvailable()) {
    error_text = L"语气润色未配置完成。";
    AuditLogger::Log(L"ai_assistant",
                     L"Polish rejected: rewrite is not available");
    return false;
  }
  AuditLogger::Log(
      L"ai_assistant",
      L"Polish request started, tone=" +
          std::to_wstring(static_cast<int>(tone)) + L", input_chars=" +
          std::to_wstring(input_text.size()));

  const std::wstring system_prompt =
      L"你是中文表达润色助手。请只输出最终润色结果，不要解释，不要编号，不要加引号。"
      L"保留原意，不要凭空补充事实。";
  const std::wstring user_message =
      L"请把下面这段话改写得" + ToneToInstruction(tone) + L"\n\n原文：\n" +
      input_text;
  return RunChatLikeRequest(system_prompt, {}, user_message, response_text,
                            error_text);
}

bool AIAssistantService::TranscribeAudioFile(const std::wstring& file_path,
                                             std::wstring& response_text,
                                             std::wstring& error_text) const {
  if (!IsAsrAvailable()) {
    error_text = L"音频转写未配置完成。";
    AuditLogger::Log(L"ai_assistant", L"Transcribe rejected: ASR is not available");
    return false;
  }
  AuditLogger::Log(L"ai_assistant",
                   L"Transcribe request started, file=" + file_path);

  std::vector<uint8_t> payload;
  std::wstring content_type;
  if (!BuildTranscriptionPayload(file_path, payload, content_type,
                                 error_text)) {
    AuditLogger::Log(L"ai_assistant",
                     L"Transcribe payload build failed: " + error_text);
    return false;
  }

  std::vector<std::pair<std::string, std::string>> headers;
  if (!m_asr_api_key.empty()) {
    headers.emplace_back("Authorization", "Bearer " + m_asr_api_key);
  }

  std::string response_body;
  if (!ExecuteMultipartRequest(m_asr_api_url, headers, payload, content_type,
                               m_asr_timeout_ms, response_body, error_text)) {
    AuditLogger::Log(L"ai_assistant",
                     L"Transcribe request failed: " + error_text);
    return false;
  }

  response_text = ParseTranscriptionResponse(response_body);
  if (response_text.empty()) {
    error_text = L"音频转写响应为空或格式不符合预期。";
    AuditLogger::Log(L"ai_assistant",
                     L"Transcribe response parse failed: empty content");
    return false;
  }
  AuditLogger::Log(L"ai_assistant",
                   L"Transcribe request finished, text_chars=" +
                       std::to_wstring(response_text.size()));
  return true;
}

bool AIAssistantService::ExecuteJsonRequest(
    const std::string& url,
    const std::vector<std::pair<std::string, std::string>>& headers,
    const std::string& request_body,
    int timeout_ms,
    std::string& response_body,
    std::wstring& error_text) const {
  const std::vector<uint8_t> body(request_body.begin(), request_body.end());
  AuditLogger::Log(L"ai_assistant",
                   L"ExecuteJsonRequest, url=" + u8tow(url) +
                       L", body_bytes=" + std::to_wstring(body.size()) +
                       L", timeout_ms=" + std::to_wstring(timeout_ms));
  return ExecuteMultipartRequest(url, headers, body, L"application/json",
                                 timeout_ms, response_body, error_text);
}

bool AIAssistantService::ExecuteMultipartRequest(
    const std::string& url,
    const std::vector<std::pair<std::string, std::string>>& headers,
    const std::vector<uint8_t>& request_body,
    const std::wstring& content_type,
    int timeout_ms,
    std::string& response_body,
    std::wstring& error_text) const {
  response_body.clear();
  AuditLogger::Log(L"ai_assistant",
                   L"HTTP request started, url=" + u8tow(url) +
                       L", content_type=" + content_type + L", body_bytes=" +
                       std::to_wstring(request_body.size()) + L", timeout_ms=" +
                       std::to_wstring(timeout_ms));

  const std::wstring url_w = u8tow(url);
  URL_COMPONENTS url_components = {0};
  wchar_t host_name[256] = {0};
  wchar_t url_path[2048] = {0};
  wchar_t extra_info[1024] = {0};
  url_components.dwStructSize = sizeof(url_components);
  url_components.lpszHostName = host_name;
  url_components.dwHostNameLength = _countof(host_name);
  url_components.lpszUrlPath = url_path;
  url_components.dwUrlPathLength = _countof(url_path);
  url_components.lpszExtraInfo = extra_info;
  url_components.dwExtraInfoLength = _countof(extra_info);

  if (!WinHttpCrackUrl(url_w.c_str(), 0, 0, &url_components)) {
    error_text = L"URL 解析失败：" + url_w;
    AuditLogger::Log(L"ai_assistant", L"HTTP request failed: " + error_text);
    return false;
  }

  std::wstring path = url_path;
  if (url_components.dwExtraInfoLength > 0) {
    path.append(extra_info, url_components.dwExtraInfoLength);
  }

  const std::wstring host_name_w(host_name, url_components.dwHostNameLength);
  const bool is_localhost = IsLocalHostName(host_name_w);
  const DWORD access_type = is_localhost ? WINHTTP_ACCESS_TYPE_NO_PROXY
                                         : WINHTTP_ACCESS_TYPE_DEFAULT_PROXY;

  HINTERNET session =
      WinHttpOpen(L"Wisdom-Weasel AI Assistant/1.0", access_type,
                  is_localhost ? (LPCWSTR)WINHTTP_NO_PROXY_NAME : NULL,
                  is_localhost ? (LPCWSTR)WINHTTP_NO_PROXY_BYPASS : NULL, 0);
  if (!session) {
    error_text = GetWinHttpErrorMessage(L"打开 HTTP 会话");
    AuditLogger::Log(L"ai_assistant", L"HTTP request failed: " + error_text);
    return false;
  }

  const int resolve_timeout_ms = is_localhost ? 10000 : timeout_ms;
  const int connect_timeout_ms = is_localhost ? 10000 : timeout_ms;
  const int send_timeout_ms = is_localhost ? 15000 : timeout_ms;
  const int receive_timeout_ms = is_localhost ? (std::max)(timeout_ms, 60000)
                                              : timeout_ms;
  if (!WinHttpSetTimeouts(session, resolve_timeout_ms, connect_timeout_ms,
                          send_timeout_ms, receive_timeout_ms)) {
    WinHttpCloseHandle(session);
    error_text = GetWinHttpErrorMessage(L"设置 HTTP 超时");
    AuditLogger::Log(L"ai_assistant", L"HTTP request failed: " + error_text);
    return false;
  }

  HINTERNET connect =
      WinHttpConnect(session, host_name, url_components.nPort, 0);
  if (!connect) {
    WinHttpCloseHandle(session);
    error_text = GetWinHttpErrorMessage(L"连接服务器");
    AuditLogger::Log(L"ai_assistant", L"HTTP request failed: " + error_text);
    return false;
  }

  const DWORD request_flags =
      url_components.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0;
  HINTERNET request = WinHttpOpenRequest(connect, L"POST", path.c_str(), NULL,
                                         WINHTTP_NO_REFERER,
                                         WINHTTP_DEFAULT_ACCEPT_TYPES,
                                         request_flags);
  if (!request) {
    WinHttpCloseHandle(connect);
    WinHttpCloseHandle(session);
    error_text = GetWinHttpErrorMessage(L"创建 HTTP 请求");
    AuditLogger::Log(L"ai_assistant", L"HTTP request failed: " + error_text);
    return false;
  }

  std::wstring header_blob = L"Content-Type: " + content_type + L"\r\n";
  for (const auto& header : headers) {
    header_blob += u8tow(header.first) + L": " + u8tow(header.second) + L"\r\n";
  }

  const BOOL send_ok =
      WinHttpSendRequest(request, header_blob.c_str(),
                         static_cast<DWORD>(header_blob.length()),
                         request_body.empty()
                             ? WINHTTP_NO_REQUEST_DATA
                             : const_cast<uint8_t*>(request_body.data()),
                         static_cast<DWORD>(request_body.size()),
                         static_cast<DWORD>(request_body.size()), 0);
  if (!send_ok) {
    error_text = GetWinHttpErrorMessage(L"发送 HTTP 请求");
    WinHttpCloseHandle(request);
    WinHttpCloseHandle(connect);
    WinHttpCloseHandle(session);
    AuditLogger::Log(L"ai_assistant", L"HTTP request failed: " + error_text);
    return false;
  }

  if (!WinHttpReceiveResponse(request, nullptr)) {
    error_text = GetWinHttpErrorMessage(L"接收 HTTP 响应");
    WinHttpCloseHandle(request);
    WinHttpCloseHandle(connect);
    WinHttpCloseHandle(session);
    AuditLogger::Log(L"ai_assistant", L"HTTP request failed: " + error_text);
    return false;
  }

  DWORD status_code = 0;
  DWORD status_code_size = sizeof(status_code);
  WinHttpQueryHeaders(request,
                      WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                      WINHTTP_HEADER_NAME_BY_INDEX, &status_code,
                      &status_code_size, WINHTTP_NO_HEADER_INDEX);

  DWORD bytes_available = 0;
  do {
    bytes_available = 0;
    if (!WinHttpQueryDataAvailable(request, &bytes_available)) {
      error_text = GetWinHttpErrorMessage(L"读取 HTTP 响应长度");
      WinHttpCloseHandle(request);
      WinHttpCloseHandle(connect);
      WinHttpCloseHandle(session);
      AuditLogger::Log(L"ai_assistant", L"HTTP request failed: " + error_text);
      return false;
    }

    if (bytes_available == 0) {
      break;
    }

    std::string chunk(bytes_available, '\0');
    DWORD bytes_read = 0;
    if (!WinHttpReadData(request, chunk.data(), bytes_available, &bytes_read)) {
      error_text = GetWinHttpErrorMessage(L"读取 HTTP 响应内容");
      WinHttpCloseHandle(request);
      WinHttpCloseHandle(connect);
      WinHttpCloseHandle(session);
      AuditLogger::Log(L"ai_assistant", L"HTTP request failed: " + error_text);
      return false;
    }
    chunk.resize(bytes_read);
    response_body += chunk;
  } while (bytes_available > 0);

  WinHttpCloseHandle(request);
  WinHttpCloseHandle(connect);
  WinHttpCloseHandle(session);

  if (status_code < 200 || status_code >= 300) {
    error_text = L"服务返回 HTTP " + std::to_wstring(status_code);
    if (!response_body.empty()) {
      std::wstring body_preview = TrimWhitespace(u8tow(response_body));
      if (body_preview.size() > 200) {
        body_preview.resize(200);
        body_preview += L"...";
      }
      error_text += L"：" + body_preview;
    }
    AuditLogger::Log(L"ai_assistant",
                     L"HTTP request finished with error: " + error_text);
    return false;
  }
  AuditLogger::Log(L"ai_assistant",
                   L"HTTP request finished, status=HTTP " +
                       std::to_wstring(status_code) + L", response_bytes=" +
                       std::to_wstring(response_body.size()));
  return true;
}

bool AIAssistantService::RunChatLikeRequest(
    const std::wstring& system_prompt,
    const std::vector<ConversationTurn>& history,
    const std::wstring& user_message,
    std::wstring& response_text,
    std::wstring& error_text) const {
  std::ostringstream json;
  json.imbue(std::locale::classic());
  json << "{"
       << "\"model\":\""
       << weasel::config_json::EscapeJsonString(m_chat_model) << "\","
       << "\"messages\":[";

  auto append_message = [&json](const std::wstring& role,
                                const std::wstring& content,
                                bool& first) {
    if (!first) {
      json << ",";
    }
    first = false;
    json << "{"
         << "\"role\":\""
         << weasel::config_json::EscapeJsonString(wtou8(role)) << "\","
         << "\"content\":\""
         << weasel::config_json::EscapeJsonString(wtou8(content)) << "\""
         << "}";
  };

  bool first_message = true;
  append_message(L"system", system_prompt, first_message);

  const size_t start_index =
      history.size() > kMaxConversationTurns ? history.size() - kMaxConversationTurns
                                             : 0;
  for (size_t i = start_index; i < history.size(); ++i) {
    append_message(history[i].role.empty() ? L"user" : history[i].role,
                   history[i].text, first_message);
  }
  append_message(L"user", user_message, first_message);

  const bool is_local_ollama = IsLocalOllamaUrl(m_chat_api_url);
  json << "],\"temperature\":" << std::setprecision(3) << m_chat_temperature
       << ",\"stream\":false";
  if (is_local_ollama) {
    json << ",\"reasoning_effort\":\"none\",\"think\":false";
  }
  json << "}";

  std::vector<std::pair<std::string, std::string>> headers;
  if (!m_chat_api_key.empty()) {
    headers.emplace_back("Authorization", "Bearer " + m_chat_api_key);
  }

  std::string response_body;
  if (!ExecuteJsonRequest(m_chat_api_url, headers, json.str(),
                          m_chat_timeout_ms, response_body, error_text)) {
    AuditLogger::Log(L"ai_assistant",
                     L"RunChatLikeRequest failed: " + error_text);
    return false;
  }

  response_text = ParseChatResponse(response_body);
  if (response_text.empty()) {
    error_text = L"AI 回复为空或格式不符合预期。";
    AuditLogger::Log(L"ai_assistant",
                     L"RunChatLikeRequest failed: empty parsed response");
    return false;
  }
  AuditLogger::Log(L"ai_assistant",
                   L"RunChatLikeRequest finished, response_chars=" +
                       std::to_wstring(response_text.size()));
  return true;
}

bool AIAssistantService::BuildTranscriptionPayload(
    const std::wstring& file_path,
    std::vector<uint8_t>& payload,
    std::wstring& content_type,
    std::wstring& error_text) const {
  namespace fs = std::filesystem;
  const fs::path path(file_path);
  if (file_path.empty() || !fs::exists(path) || !fs::is_regular_file(path)) {
    error_text = L"音频文件不存在。";
    return false;
  }

  std::ifstream file(path, std::ios::binary);
  if (!file) {
    error_text = L"无法读取音频文件。";
    return false;
  }

  file.seekg(0, std::ios::end);
  const std::streamoff file_size = file.tellg();
  file.seekg(0, std::ios::beg);
  if (file_size <= 0) {
    error_text = L"音频文件为空。";
    return false;
  }
  if (file_size > 25LL * 1024LL * 1024LL) {
    error_text = L"音频文件过大，建议控制在 25 MB 以内。";
    return false;
  }

  std::vector<uint8_t> file_bytes(static_cast<size_t>(file_size));
  file.read(reinterpret_cast<char*>(file_bytes.data()),
            static_cast<std::streamsize>(file_bytes.size()));
  if (!file) {
    error_text = L"读取音频文件失败。";
    return false;
  }

  const std::string boundary =
      "---------------------------WisdomWeaselAIAssistant";
  payload.clear();
  AppendMultipartField(payload, boundary, "model", m_asr_model);
  if (!m_asr_language.empty()) {
    AppendMultipartField(payload, boundary, "language", m_asr_language);
  }
  AppendMultipartField(payload, boundary, "response_format", "json");
  AppendMultipartFile(payload, boundary, "file", path.filename().wstring(),
                      GetMimeTypeForPath(path), file_bytes);
  AppendUtf8(payload, "--" + boundary + "--\r\n");

  content_type = L"multipart/form-data; boundary=" + u8tow(boundary);
  return true;
}

std::wstring AIAssistantService::ParseChatResponse(
    const std::string& json_response) const {
  try {
    std::istringstream json_stream(json_response);
    boost::property_tree::ptree root;
    boost::property_tree::read_json(json_stream, root);

    const auto choices = root.get_child_optional("choices");
    if (choices) {
      for (const auto& choice : *choices) {
        const auto message_content =
            choice.second.get_optional<std::string>("message.content");
        if (message_content && !message_content->empty()) {
          return TrimWhitespace(u8tow(*message_content));
        }
        const auto text_content = choice.second.get_optional<std::string>("text");
        if (text_content && !text_content->empty()) {
          return TrimWhitespace(u8tow(*text_content));
        }
      }
    }

    const auto direct_message = root.get_optional<std::string>("message.content");
    if (direct_message && !direct_message->empty()) {
      return TrimWhitespace(u8tow(*direct_message));
    }

    const auto direct_text = root.get_optional<std::string>("text");
    if (direct_text && !direct_text->empty()) {
      return TrimWhitespace(u8tow(*direct_text));
    }
  } catch (const boost::property_tree::json_parser_error&) {
  }

  return TrimWhitespace(u8tow(json_response));
}

std::wstring AIAssistantService::ParseTranscriptionResponse(
    const std::string& response_body) const {
  try {
    std::istringstream json_stream(response_body);
    boost::property_tree::ptree root;
    boost::property_tree::read_json(json_stream, root);
    const auto text = root.get_optional<std::string>("text");
    if (text && !text->empty()) {
      return TrimWhitespace(u8tow(*text));
    }
  } catch (const boost::property_tree::json_parser_error&) {
  }

  return TrimWhitespace(u8tow(response_body));
}
