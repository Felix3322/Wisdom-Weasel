#pragma once

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

class AIAssistantService {
 public:
  enum class TonePreset : uint8_t {
    Cute = 0,
    Formal = 1,
    Rigorous = 2,
    Playful = 3,
  };

  struct ConversationTurn {
    std::wstring role;
    std::wstring text;
  };

  AIAssistantService();
  ~AIAssistantService();

  bool LoadConfig(const std::string& config_name);

  bool IsEnabled() const { return m_enabled; }
  bool IsChatAvailable() const;
  bool IsRewriteAvailable() const;
  bool IsAsrAvailable() const;
  std::wstring GetAvailabilityHint() const { return m_availability_hint; }

  bool Chat(const std::vector<ConversationTurn>& history,
            const std::wstring& user_message,
            std::wstring& response_text,
            std::wstring& error_text) const;
  bool Polish(const std::wstring& input_text,
              TonePreset tone,
              std::wstring& response_text,
              std::wstring& error_text) const;
  bool TranscribeAudioFile(const std::wstring& file_path,
                           std::wstring& response_text,
                           std::wstring& error_text) const;

 private:
  bool ExecuteJsonRequest(const std::string& url,
                          const std::vector<std::pair<std::string, std::string>>&
                              headers,
                          const std::string& request_body,
                          int timeout_ms,
                          std::string& response_body,
                          std::wstring& error_text) const;
  bool ExecuteMultipartRequest(
      const std::string& url,
      const std::vector<std::pair<std::string, std::string>>& headers,
      const std::vector<uint8_t>& request_body,
      const std::wstring& content_type,
      int timeout_ms,
      std::string& response_body,
      std::wstring& error_text) const;

  bool RunChatLikeRequest(const std::wstring& system_prompt,
                          const std::vector<ConversationTurn>& history,
                          const std::wstring& user_message,
                          std::wstring& response_text,
                          std::wstring& error_text) const;

  bool BuildTranscriptionPayload(const std::wstring& file_path,
                                 std::vector<uint8_t>& payload,
                                 std::wstring& content_type,
                                 std::wstring& error_text) const;

  std::wstring ParseChatResponse(const std::string& json_response) const;
  std::wstring ParseTranscriptionResponse(
      const std::string& response_body) const;

 private:
  bool m_enabled;
  std::string m_chat_api_url;
  std::string m_chat_api_key;
  std::string m_chat_model;
  double m_chat_temperature;
  int m_chat_timeout_ms;
  std::wstring m_chat_system_prompt;

  std::string m_asr_api_url;
  std::string m_asr_api_key;
  std::string m_asr_model;
  std::string m_asr_language;
  int m_asr_timeout_ms;

  std::wstring m_availability_hint;
};
