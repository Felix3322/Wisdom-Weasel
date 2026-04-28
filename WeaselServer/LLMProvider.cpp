#include "stdafx.h"
#include "LLMProvider.h"
#include "ConfigJsonUtils.h"
#include "DevConsole.h"
#include <WeaselUtility.h>
#include <rime_api.h>
#include <winhttp.h>
#include <boost/property_tree/json_parser.hpp>
#include <boost/property_tree/ptree.hpp>
#include <sstream>
#include <algorithm>
#include <cctype>
#include <cstring>
#include <cwctype>

#pragma comment(lib, "winhttp.lib")

namespace {

bool HeaderNameEquals(const std::string& lhs, const char* rhs) {
  if (!rhs || lhs.size() != strlen(rhs)) {
    return false;
  }

  for (size_t i = 0; i < lhs.size(); ++i) {
    if (std::tolower(static_cast<unsigned char>(lhs[i])) !=
        std::tolower(static_cast<unsigned char>(rhs[i]))) {
      return false;
    }
  }
  return true;
}

bool HasHeaderNamed(
    const std::vector<std::pair<std::string, std::string>>& headers,
    const char* header_name) {
  for (const auto& header : headers) {
    if (HeaderNameEquals(header.first, header_name)) {
      return true;
    }
  }
  return false;
}

std::string StripJsonObjectBraces(const std::string& json_object) {
  if (json_object.size() < 2 || json_object.front() != '{' ||
      json_object.back() != '}') {
    return std::string();
  }
  return json_object.substr(1, json_object.size() - 2);
}

bool FindFirstStringFieldByName(const boost::property_tree::ptree& node,
                                const char* field_name,
                                std::string& value) {
  for (const auto& child : node) {
    if (child.first == field_name) {
      const std::string field_value = child.second.get_value<std::string>();
      if (!field_value.empty()) {
        value = field_value;
        return true;
      }
    }

    if (FindFirstStringFieldByName(child.second, field_name, value)) {
      return true;
    }
  }

  return false;
}

bool IsDigitWide(wchar_t ch) {
  return ch >= L'0' && ch <= L'9';
}

bool IsCandidateWrapperChar(wchar_t ch) {
  switch (ch) {
    case L'"':
    case L'\'':
    case L'`':
    case L',':
    case L'.':
    case L';':
    case L':':
    case L'!':
    case L'?':
    case L'(':
    case L')':
    case L'[':
    case L']':
    case L'{':
    case L'}':
    case L'<':
    case L'>':
    case L'|':
    case L'/':
    case L'\\':
    case L'·':
    case L'，':
    case L'。':
    case L'；':
    case L'：':
    case L'！':
    case L'？':
    case L'（':
    case L'）':
    case L'【':
    case L'】':
    case L'「':
    case L'」':
    case L'『':
    case L'』':
    case L'“':
    case L'”':
    case L'‘':
    case L'’':
      return true;
    default:
      return false;
  }
}

bool IsCjkIdeographChar(wchar_t ch) {
  return (ch >= 0x3400 && ch <= 0x4DBF) || (ch >= 0x4E00 && ch <= 0x9FFF) ||
         (ch >= 0xF900 && ch <= 0xFAFF);
}

bool IsEmojiLikeCodeUnit(wchar_t ch) {
  return (ch >= 0x2600 && ch <= 0x27BF) || (ch >= 0xD83C && ch <= 0xDBFF) ||
         (ch >= 0xDC00 && ch <= 0xDFFF) || ch == 0x200D || ch == 0xFE0F;
}

bool IsAsciiKaomojiLetter(wchar_t ch) {
  switch (std::towlower(ch)) {
    case L'q':
    case L'w':
    case L'o':
    case L'u':
    case L'v':
    case L'x':
    case L't':
    case L'm':
      return true;
    default:
      return false;
  }
}

bool IsQuoteWrapperChar(wchar_t ch) {
  switch (ch) {
    case L'"':
    case L'\'':
    case L'`':
    case L'“':
    case L'”':
    case L'‘':
    case L'’':
      return true;
    default:
      return false;
  }
}

bool IsEmoticonSignalChar(wchar_t ch) {
  switch (ch) {
    case L':':
    case L';':
    case L'=':
    case L'^':
    case L'~':
    case L'T':
    case L't':
    case L'X':
    case L'x':
    case L'8':
      return true;
    default:
      return false;
  }
}

bool IsKaomojiStructuralChar(wchar_t ch) {
  switch (ch) {
    case L'^':
    case L'_':
    case L'~':
    case L'=':
    case L'*':
    case L'-':
    case L'/':
    case L'\\':
    case L'|':
    case L'°':
    case L'•':
    case L'ω':
    case L'▽':
    case L'∀':
    case L'╯':
    case L'╰':
    case L'¯':
    case L'ツ':
    case L'つ':
    case L'ノ':
    case L'ヽ':
    case L'ง':
    case L'๑':
    case L'ㅂ':
    case L'ಠ':
    case L'益':
    case L'♥':
      return true;
    default:
      return false;
  }
}

std::wstring TrimCandidateWhitespace(std::wstring token) {
  while (!token.empty() && std::iswspace(token.front())) {
    token.erase(token.begin());
  }
  while (!token.empty() && std::iswspace(token.back())) {
    token.pop_back();
  }
  return token;
}

void StripLeadingIndexPrefix(std::wstring& token) {
  size_t prefix_digits = 0;
  while (prefix_digits < token.size() && IsDigitWide(token[prefix_digits])) {
    ++prefix_digits;
  }
  if (prefix_digits > 0 && prefix_digits < token.size()) {
    const wchar_t marker = token[prefix_digits];
    if (marker == L'.' || marker == L'、' || marker == L')' ||
        marker == L']' || marker == L'：' || marker == L':') {
      token.erase(0, prefix_digits + 1);
    }
  }
}

bool LooksLikeExpressiveToken(const std::wstring& token) {
  if (token.empty()) {
    return false;
  }

  size_t visible_count = 0;
  size_t structural_count = 0;
  size_t expressive_letter_count = 0;
  size_t emoticon_signal_count = 0;
  size_t generic_punct_count = 0;
  bool has_emoji_like_unit = false;
  bool has_kaomoji_signal = false;

  for (wchar_t ch : token) {
    if (std::iswspace(ch)) {
      continue;
    }
    ++visible_count;
    if (IsCjkIdeographChar(ch) || IsDigitWide(ch)) {
      return false;
    }
    if (IsEmojiLikeCodeUnit(ch)) {
      has_emoji_like_unit = true;
      continue;
    }
    if (std::iswalpha(ch)) {
      if (!IsAsciiKaomojiLetter(ch)) {
        return false;
      }
      ++expressive_letter_count;
      continue;
    }
    if (IsKaomojiStructuralChar(ch)) {
      ++structural_count;
      has_kaomoji_signal = true;
      continue;
    }
    if (IsCandidateWrapperChar(ch) || std::iswpunct(ch)) {
      ++generic_punct_count;
      if (IsEmoticonSignalChar(ch)) {
        ++emoticon_signal_count;
      }
      continue;
    }
    if (ch < 0x0080) {
      return false;
    }
    ++generic_punct_count;
  }

  if (visible_count == 0 || visible_count > 24) {
    return false;
  }
  if (has_emoji_like_unit) {
    return true;
  }
  if (has_kaomoji_signal &&
      (structural_count + generic_punct_count + expressive_letter_count) >=
          2) {
    return true;
  }
  if (emoticon_signal_count >= 1 && generic_punct_count >= 2 &&
      visible_count <= 8) {
    return true;
  }
  return expressive_letter_count >= 2 &&
         (generic_punct_count + structural_count) >= 1 && visible_count <= 8;
}

std::wstring NormalizeExpressiveCandidateToken(std::wstring token) {
  token = TrimCandidateWhitespace(std::move(token));
  if (token.empty()) {
    return std::wstring();
  }

  StripLeadingIndexPrefix(token);
  token = TrimCandidateWhitespace(std::move(token));
  if (token.empty()) {
    return std::wstring();
  }

  while (!token.empty() && IsQuoteWrapperChar(token.front())) {
    token.erase(token.begin());
  }
  while (!token.empty() && IsQuoteWrapperChar(token.back())) {
    token.pop_back();
  }
  token = TrimCandidateWhitespace(std::move(token));
  if (token.empty()) {
    return std::wstring();
  }

  if (LooksLikeExpressiveToken(token)) {
    return token;
  }
  return std::wstring();
}

std::wstring NormalizeCandidateToken(std::wstring token) {
  // Strip prefix wrapper chars
  auto start_it = std::find_if_not(token.begin(), token.end(), IsCandidateWrapperChar);
  // Strip suffix wrapper chars
  auto end_it = std::find_if_not(token.rbegin(), token.rend(), IsCandidateWrapperChar).base();

  if (start_it >= end_it) {
    return std::wstring();
  }

  token.erase(token.begin(), start_it);
  // Recompute end_it since iterators may be invalidated
  end_it = std::find_if_not(token.rbegin(), token.rend(), IsCandidateWrapperChar).base();
  if (end_it <= token.begin()) {
    return std::wstring();
  }
  token.erase(end_it, token.end());

  // Strip leading index prefix like "1." or "1、"
  size_t prefix_digits = 0;
  while (prefix_digits < token.size() && IsDigitWide(token[prefix_digits])) {
    ++prefix_digits;
  }
  if (prefix_digits > 0 && prefix_digits < token.size()) {
    const wchar_t marker = token[prefix_digits];
    if (marker == L'.' || marker == L'、' || marker == L')' || marker == L']' ||
        marker == L'：' || marker == L':') {
      token.erase(0, prefix_digits + 1);
    }
  }

  // Final cleanup strip
  start_it = std::find_if_not(token.begin(), token.end(), IsCandidateWrapperChar);
  end_it = std::find_if_not(token.rbegin(), token.rend(), IsCandidateWrapperChar).base();
  if (start_it < end_it) {
    token.erase(token.begin(), start_it);
    token.erase(end_it, token.end());
  }

  return token;
}

bool IsIgnorableCandidateToken(const std::wstring& token) {
  if (token.empty()) {
    return true;
  }
  if (LooksLikeExpressiveToken(token)) {
    return false;
  }

  std::wstring lower;
  lower.reserve(token.size());
  for (wchar_t ch : token) {
    lower.push_back(static_cast<wchar_t>(std::towlower(ch)));
  }
  static const wchar_t* kForbiddenPrefixes[] = {
      L"th",        L"think",    L"thinking", L"reason",
      L"reasoning", L"analysis", L"process",  L"step"};
  for (const wchar_t* prefix : kForbiddenPrefixes) {
    const size_t prefix_len = wcslen(prefix);
    if (lower.size() >= prefix_len &&
        lower.compare(0, prefix_len, prefix) == 0) {
      return true;
    }
  }
  if (lower.find(L"thinking") != std::wstring::npos ||
      lower.find(L"reasoning") != std::wstring::npos) {
    return true;
  }

  bool all_digits_or_punct = true;
  for (wchar_t ch : token) {
    if (!IsDigitWide(ch) && !IsCandidateWrapperChar(ch)) {
      all_digits_or_punct = false;
      break;
    }
  }
  return all_digits_or_punct;
}

std::vector<std::wstring> ExtractCandidatesFromUtf8Text(
    const std::string& text_utf8,
    size_t max_candidates,
    bool allow_expressive_tokens = false) {
  std::vector<std::wstring> candidates;
  if (text_utf8.empty()) {
    return candidates;
  }

  const std::wstring content_w = u8tow(text_utf8);
  std::wstringstream ss(content_w);
  std::wstring raw_token;
  while (ss >> raw_token) {
    std::wstring token;
    if (allow_expressive_tokens) {
      token = NormalizeExpressiveCandidateToken(raw_token);
    }
    if (token.empty()) {
      token = NormalizeCandidateToken(raw_token);
    }
    if (IsIgnorableCandidateToken(token)) {
      continue;
    }
    if (!allow_expressive_tokens && LooksLikeExpressiveToken(token)) {
      continue;
    }
    if (std::find(candidates.begin(), candidates.end(), token) !=
        candidates.end()) {
      continue;
    }
    candidates.push_back(token);
    if (max_candidates > 0 && candidates.size() >= max_candidates) {
      break;
    }
  }
  return candidates;
}

bool ExtractContentFromOpenAIChunkPayload(const std::string& payload,
                                          std::string& delta_content,
                                          bool& finished) {
  delta_content.clear();
  finished = false;

  try {
    boost::property_tree::ptree root;
    std::istringstream json_stream(payload);
    boost::property_tree::read_json(json_stream, root);

    const auto choices = root.get_child_optional("choices");
    if (!choices || choices->empty()) {
      return false;
    }

    const auto& choice = choices->front().second;
    if (const auto finish_reason =
            choice.get_optional<std::string>("finish_reason")) {
      finished = !finish_reason->empty() && *finish_reason != "null";
    }

    if (const auto delta = choice.get_child_optional("delta")) {
      if (const auto content = delta->get_optional<std::string>("content")) {
        delta_content = *content;
      }
    }

    if (delta_content.empty()) {
      if (const auto message = choice.get_child_optional("message")) {
        if (const auto content =
                message->get_optional<std::string>("content")) {
          delta_content = *content;
        }
      }
    }

    if (delta_content.empty()) {
      const char* field_names[] = {"content", "text", "generated_text",
                                   "responses"};
      for (const char* field_name : field_names) {
        if (FindFirstStringFieldByName(root, field_name, delta_content)) {
          break;
        }
      }
    }
  } catch (const boost::property_tree::json_parser_error&) {
    return false;
  }

  return finished || !delta_content.empty();
}

std::string ExtractContentFromSseResponse(const std::string& sse_response) {
  std::stringstream input(sse_response);
  std::string line;
  std::string aggregated_content;

  while (std::getline(input, line)) {
    if (!line.empty() && line.back() == '\r') {
      line.pop_back();
    }
    if (line.empty() || line.rfind("data: ", 0) != 0) {
      continue;
    }

    const std::string payload = line.substr(6);
    if (payload == "[DONE]") {
      break;
    }

    std::string delta_content;
    bool finished = false;
    if (ExtractContentFromOpenAIChunkPayload(payload, delta_content,
                                             finished)) {
      aggregated_content += delta_content;
      if (finished) {
        break;
      }
    }
  }

  return aggregated_content;
}

bool ExtractResponseFromOllamaGenerateChunkPayload(const std::string& payload,
                                                   std::string& delta_content,
                                                   bool& finished) {
  delta_content.clear();
  finished = false;

  try {
    boost::property_tree::ptree root;
    std::istringstream json_stream(payload);
    boost::property_tree::read_json(json_stream, root);
    if (const auto response = root.get_optional<std::string>("response")) {
      delta_content = *response;
    }
    if (const auto done = root.get_optional<bool>("done")) {
      finished = *done;
    }
  } catch (const boost::property_tree::json_parser_error&) {
    return false;
  }

  return finished || !delta_content.empty();
}

std::string ExtractContentFromOllamaGenerateResponse(
    const std::string& generate_response) {
  std::stringstream input(generate_response);
  std::string line;
  std::string aggregated_content;

  while (std::getline(input, line)) {
    if (!line.empty() && line.back() == '\r') {
      line.pop_back();
    }
    if (line.empty()) {
      continue;
    }
    std::string delta_content;
    bool finished = false;
    if (ExtractResponseFromOllamaGenerateChunkPayload(line, delta_content,
                                                      finished)) {
      aggregated_content += delta_content;
      if (finished) {
        break;
      }
    }
  }

  return aggregated_content;
}

std::wstring TrimLeadingWhitespaceAndPunctuation(std::wstring text) {
  while (!text.empty() && std::iswspace(text.front())) {
    text.erase(text.begin());
  }
  if (LooksLikeExpressiveToken(text)) {
    return text;
  }
  while (!text.empty() && IsCandidateWrapperChar(text.front())) {
    text.erase(text.begin());
  }
  while (!text.empty() && std::iswspace(text.back())) {
    text.pop_back();
  }
  return text;
}

std::wstring RemovePromptEcho(const std::wstring& prompt,
                              std::wstring generated) {
  if (generated.empty()) {
    return generated;
  }

  size_t start = 0;
  while (start < generated.size() && std::iswspace(generated[start])) {
    ++start;
  }

  size_t overlap = 0;
  const size_t max_overlap =
      (std::min)(prompt.size(), generated.size() - start);
  for (size_t len = max_overlap; len > 0; --len) {
    if (prompt.compare(prompt.size() - len, len, generated, start, len) == 0) {
      overlap = len;
      break;
    }
  }

  generated.erase(0, start + overlap);
  return TrimLeadingWhitespaceAndPunctuation(generated);
}

std::vector<std::wstring> BuildContinuationCandidates(
    const std::wstring& prompt,
    const std::wstring& generated,
    size_t max_candidates,
    bool allow_expressive_tokens = false) {
  std::vector<std::wstring> candidates;
  std::wstring continuation = RemovePromptEcho(prompt, generated);
  if (continuation.empty()) {
    return candidates;
  }

  size_t clause_end = continuation.find_first_of(L"\r\n。！？!?；;，,、");
  if (clause_end != std::wstring::npos && clause_end > 0) {
    continuation = continuation.substr(0, clause_end);
  }
  continuation = TrimLeadingWhitespaceAndPunctuation(continuation);
  if (continuation.empty()) {
    return candidates;
  }

  static const size_t kMaxVisibleCandidateLen = 16u;
  static const size_t kPreferredLengths[] = {2, 3, 4, 5, 6, 8, 12, 16};
  const size_t visible_len = (std::min)(continuation.size(), kMaxVisibleCandidateLen);
  for (size_t preferred_len : kPreferredLengths) {
    if (preferred_len > visible_len) {
      continue;
    }
    std::wstring candidate = continuation.substr(0, preferred_len);
    if (allow_expressive_tokens) {
      candidate = NormalizeExpressiveCandidateToken(candidate);
    }
    if (candidate.empty()) {
      candidate = NormalizeCandidateToken(continuation.substr(0, preferred_len));
    }
    if (IsIgnorableCandidateToken(candidate)) {
      continue;
    }
    if (std::find(candidates.begin(), candidates.end(), candidate) ==
        candidates.end()) {
      candidates.push_back(candidate);
    }
    if (max_candidates > 0 && candidates.size() >= max_candidates) {
      return candidates;
    }
  }

  std::wstring full_candidate = continuation.substr(0, visible_len);
  if (allow_expressive_tokens) {
    full_candidate = NormalizeExpressiveCandidateToken(full_candidate);
  }
  if (full_candidate.empty()) {
    full_candidate = NormalizeCandidateToken(continuation.substr(0, visible_len));
  }
  if (!IsIgnorableCandidateToken(full_candidate) &&
      std::find(candidates.begin(), candidates.end(), full_candidate) ==
          candidates.end()) {
    candidates.push_back(full_candidate);
  }

  if (max_candidates > 0 && candidates.size() > max_candidates) {
    candidates.resize(max_candidates);
  }
  return candidates;
}

std::wstring BuildNoInputShortCandidateDiversityKey(
    const std::wstring& candidate) {
  std::wstring normalized = candidate;
  normalized.erase(
      std::remove_if(normalized.begin(), normalized.end(),
                     [](wchar_t ch) { return std::iswspace(ch) != 0; }),
      normalized.end());
  if (LooksLikeExpressiveToken(normalized)) {
    return normalized;
  }
  while (!normalized.empty() &&
         normalized.back() == static_cast<wchar_t>(0xFFFD)) {
    normalized.pop_back();
  }
  if (normalized.size() <= 2) {
    return normalized;
  }
  return normalized.substr(0, 2);
}

std::vector<std::wstring> ReorderCandidatesForNoInputDiversity(
    const std::vector<std::wstring>& candidates,
    size_t max_candidates) {
  std::vector<std::wstring> reordered;
  reordered.reserve(candidates.size());
  std::vector<bool> used(candidates.size(), false);
  std::vector<std::wstring> short_diversity_keys;

  auto try_append = [&](size_t index) {
    if (index >= candidates.size() || used[index]) {
      return;
    }
    reordered.push_back(candidates[index]);
    used[index] = true;
  };

  for (size_t i = 0; i < candidates.size(); ++i) {
    const size_t candidate_len = candidates[i].size();
    const bool is_expressive = LooksLikeExpressiveToken(candidates[i]);
    if (!is_expressive && (candidate_len < 2 || candidate_len > 4)) {
      continue;
    }
    const std::wstring diversity_key =
        BuildNoInputShortCandidateDiversityKey(candidates[i]);
    if (diversity_key.empty()) {
      continue;
    }
    if (std::find(short_diversity_keys.begin(), short_diversity_keys.end(),
                  diversity_key) != short_diversity_keys.end()) {
      continue;
    }
    short_diversity_keys.push_back(diversity_key);
    try_append(i);
  }

  for (size_t i = 0; i < candidates.size(); ++i) {
    const size_t candidate_len = candidates[i].size();
    if ((candidate_len >= 2 && candidate_len <= 4) ||
        LooksLikeExpressiveToken(candidates[i])) {
      try_append(i);
    }
  }

  for (size_t i = 0; i < candidates.size(); ++i) {
    try_append(i);
  }

  if (max_candidates > 0 && reordered.size() > max_candidates) {
    reordered.resize(max_candidates);
  }
  return reordered;
}

std::vector<std::wstring> BuildSingleContinuationCandidates(
    const std::wstring& prompt,
    const std::wstring& generated,
    size_t max_candidates,
    size_t max_len,
    const wchar_t* stop_chars,
    bool allow_expressive_tokens = false) {
  std::vector<std::wstring> candidates;
  std::wstring continuation = RemovePromptEcho(prompt, generated);
  if (continuation.empty()) {
    return candidates;
  }

  size_t clause_end = continuation.find_first_of(stop_chars);
  if (clause_end != std::wstring::npos && clause_end > 0) {
    continuation = continuation.substr(0, clause_end);
  }
  continuation = TrimLeadingWhitespaceAndPunctuation(continuation);
  if (continuation.empty()) {
    return candidates;
  }

  const size_t visible_len = (std::min)(continuation.size(), max_len);
  std::wstring candidate;
  if (allow_expressive_tokens) {
    candidate =
        NormalizeExpressiveCandidateToken(continuation.substr(0, visible_len));
  }
  if (candidate.empty()) {
    candidate = NormalizeCandidateToken(continuation.substr(0, visible_len));
  }
  if (!IsIgnorableCandidateToken(candidate)) {
    candidates.push_back(candidate);
  }
  if (max_candidates > 0 && candidates.size() > max_candidates) {
    candidates.resize(max_candidates);
  }
  return candidates;
}

std::vector<std::wstring> BuildSentenceContinuationCandidates(
    const std::wstring& prompt,
    const std::wstring& generated,
    size_t max_candidates) {
  static constexpr size_t kMaxSentenceContinuationLen = 24u;
  return BuildSingleContinuationCandidates(prompt, generated, max_candidates,
                                           kMaxSentenceContinuationLen,
                                           L"\r\n。！？!?；;");
}

bool LooksLikeLongPinyinInput(const std::wstring& text) {
  size_t alpha_count = 0;
  size_t apostrophe_count = 0;
  for (wchar_t ch : text) {
    if ((ch >= L'a' && ch <= L'z') || (ch >= L'A' && ch <= L'Z')) {
      ++alpha_count;
    } else if (ch == L'\'') {
      ++apostrophe_count;
    }
  }
  return alpha_count >= 10 || apostrophe_count >= 2;
}

bool ContainsCjkIdeographText(const std::wstring& text) {
  for (wchar_t ch : text) {
    if ((ch >= 0x3400 && ch <= 0x4DBF) || (ch >= 0x4E00 && ch <= 0x9FFF) ||
        (ch >= 0xF900 && ch <= 0xFAFF)) {
      return true;
    }
  }
  return false;
}

std::wstring BuildIndexedRimeReorderPrompt(const LLMRequest& request) {
  const size_t output_limit =
      request.max_candidates > 0
          ? (std::min)(request.max_candidates, request.rime_candidates.size())
          : request.rime_candidates.size();
  std::wstring prompt =
      L"任务：重排中文输入法候选。\n"
      L"只输出编号，空格分隔。\n"
      L"不要解释，不要输出候选词。\n";
  prompt += LooksLikeLongPinyinInput(request.current_input)
                ? L"长输入：优先整句通顺。\n"
                : L"短输入：优先自然组词。\n";
  prompt += L"拿不准就保持原顺序。\n";
  prompt += L"输出前" + std::to_wstring(output_limit) + L"个编号。\n";
  if (!request.context.empty()) {
    prompt += L"上下文：" + request.context + L"\n";
  }
  if (!request.current_input.empty()) {
    prompt += L"拼音：" + request.current_input + L"\n";
  }
  prompt += L"候选：\n";
  for (size_t i = 0; i < request.rime_candidates.size(); ++i) {
    prompt +=
        std::to_wstring(i + 1) + L". " + request.rime_candidates[i] + L"\n";
  }
  prompt += L"编号：";
  return prompt;
}

std::vector<std::wstring> ExtractRankedCandidatesFromIndices(
    const std::wstring& generated,
    const std::vector<std::wstring>& candidate_pool,
    size_t max_candidates) {
  std::vector<std::wstring> candidates;
  if (generated.empty() || candidate_pool.empty()) {
    return candidates;
  }

  std::vector<bool> used(candidate_pool.size(), false);
  size_t i = 0;
  while (i < generated.size()) {
    if (!IsDigitWide(generated[i])) {
      ++i;
      continue;
    }

    size_t value = 0;
    while (i < generated.size() && IsDigitWide(generated[i])) {
      value = value * 10 + static_cast<size_t>(generated[i] - L'0');
      ++i;
    }

    if (value == 0 || value > candidate_pool.size()) {
      continue;
    }

    const size_t index = value - 1;
    if (used[index]) {
      continue;
    }

    candidates.push_back(candidate_pool[index]);
    used[index] = true;
    if (max_candidates > 0 && candidates.size() >= max_candidates) {
      break;
    }
  }

  return candidates;
}

std::vector<std::wstring> ExtractRankedCandidatesFromTextMentions(
    const std::wstring& generated,
    const std::vector<std::wstring>& candidate_pool,
    size_t max_candidates) {
  std::vector<std::wstring> candidates;
  if (generated.empty() || candidate_pool.empty()) {
    return candidates;
  }

  std::vector<bool> used(candidate_pool.size(), false);
  for (size_t pos = 0; pos < generated.size();) {
    size_t best_index = candidate_pool.size();
    size_t best_len = 0;
    for (size_t i = 0; i < candidate_pool.size(); ++i) {
      if (used[i] || candidate_pool[i].empty()) {
        continue;
      }
      const size_t candidate_len = candidate_pool[i].size();
      if (candidate_len <= best_len || pos + candidate_len > generated.size()) {
        continue;
      }
      if (generated.compare(pos, candidate_len, candidate_pool[i]) == 0) {
        best_index = i;
        best_len = candidate_len;
      }
    }

    if (best_index < candidate_pool.size()) {
      candidates.push_back(candidate_pool[best_index]);
      used[best_index] = true;
      pos += best_len;
      if (max_candidates > 0 && candidates.size() >= max_candidates) {
        break;
      }
      continue;
    }

    ++pos;
  }

  return candidates;
}

std::vector<std::wstring> FilterCandidatesAgainstPool(
    const std::vector<std::wstring>& parsed_candidates,
    const std::vector<std::wstring>& candidate_pool,
    size_t max_candidates) {
  std::vector<std::wstring> candidates;
  for (const auto& parsed_candidate : parsed_candidates) {
    const auto it = std::find(candidate_pool.begin(), candidate_pool.end(),
                              parsed_candidate);
    if (it == candidate_pool.end()) {
      continue;
    }
    if (std::find(candidates.begin(), candidates.end(), parsed_candidate) !=
        candidates.end()) {
      continue;
    }
    candidates.push_back(parsed_candidate);
    if (max_candidates > 0 && candidates.size() >= max_candidates) {
      break;
    }
  }
  return candidates;
}

}  // namespace

namespace llm_request {

bool IsExecutable(const LLMRequest& request) {
  switch (request.type) {
    case LLMRequestType::NoInputPrediction:
      return !request.context.empty();
    case LLMRequestType::PinyinConstrainedPrediction:
      return !request.current_input.empty();
    case LLMRequestType::RimeReorder:
      return !request.rime_candidates.empty();
  }
  return false;
}

std::wstring GetRequestTypeName(LLMRequestType type) {
  switch (type) {
    case LLMRequestType::NoInputPrediction:
      return L"无输入预测";
    case LLMRequestType::PinyinConstrainedPrediction:
      return L"拼音约束预测";
    case LLMRequestType::RimeReorder:
      return L"Rime 重排";
  }
  return L"未知请求";
}

size_t GetOutputLimit(const LLMRequest& request) {
  return (std::min)(request.max_candidates,
                    request.type == LLMRequestType::RimeReorder
                        ? request.rime_candidates.size()
                        : request.max_candidates);
}

std::wstring JoinCandidatesForPrompt(
    const std::vector<std::wstring>& candidates) {
  std::wstring joined;
  for (size_t i = 0; i < candidates.size(); ++i) {
    if (i > 0) {
      joined += L"\n";
    }
    joined += std::to_wstring(i + 1) + L". \"" + candidates[i] + L"\"";
  }
  return joined;
}

std::wstring JoinCandidatesInline(const std::vector<std::wstring>& candidates) {
  std::wstring joined;
  for (size_t i = 0; i < candidates.size(); ++i) {
    if (i > 0) {
      joined += L" / ";
    }
    joined += candidates[i];
  }
  return joined;
}

InstructPrompt BuildInstructPrompt(const LLMRequest& request) {
  InstructPrompt prompt;
  const size_t output_limit = GetOutputLimit(request);

  switch (request.type) {
    case LLMRequestType::NoInputPrediction:
      prompt.system_prompt =
          L"你是一个智能中文输入法，请根据上下文预测接下来最可能出现的" +
          std::to_wstring(request.max_candidates) +
          L"个候选词。\n\n"
          L"要求：\n"
          L"1. 只返回候选词，不要任何解释或标点\n"
          L"2. 候选词之间用单个空格分隔\n"
          L"3. 按可能性从高到低排列\n"
          L"4. 优先给出 2 到 4 字的自然短词或短语；如果上下文明显在表达情绪，也可以给常见 emoji 或短颜文字\n"
          L"5. 至少包含 2 个彼此不同、不是同一前缀改写的短候选\n"
          L"6. 候选可以是有效的中文词汇、常用短语、单个 emoji 或短颜文字\n"
          L"7. 返回词数严格不超过" +
          std::to_wstring(request.max_candidates) + L"个\n";
      prompt.user_prompt = L"上下文：\"" + request.context + L"\"\n";
      prompt.user_prompt += L"候选词：";
      return prompt;
    case LLMRequestType::PinyinConstrainedPrediction:
      prompt.system_prompt =
          L"你现在扮演中文输入法助手。"
          L"我会告诉你我正在输入的拼音。"
          L"请直接给我最像输入法候选栏的中文候选。"
          L"只给候选，不要解释。";
      prompt.user_prompt = L"我现在在打“" + request.current_input + L"”。\n";
      if (!request.context.empty()) {
        prompt.user_prompt += L"前面的内容是：“" + request.context + L"”。\n";
      }
      prompt.user_prompt +=
          L"请给我 " + std::to_wstring(request.max_candidates) +
          L" 个最自然的中文候选，每行一个。"
          L"候选必须和这个拼音对应，优先 2 到 4 字、能直接上屏。";
      return prompt;
    case LLMRequestType::RimeReorder:
      prompt.system_prompt =
          L"你现在扮演中文输入法助手。"
          L"我会给你当前拼音、上下文和一组现成候选。"
          L"请把更可能上屏的候选排在前面。"
          L"只回复候选词本身，用空格分隔，不要解释。";
      prompt.user_prompt.clear();
      if (!request.current_input.empty()) {
        prompt.user_prompt += L"我现在在打“" + request.current_input + L"”。\n";
      }
      if (!request.context.empty()) {
        prompt.user_prompt += L"前面的内容是：“" + request.context + L"”。\n";
      }
      prompt.user_prompt +=
          L"现在屏幕上的候选有：" +
          JoinCandidatesInline(request.rime_candidates) +
          L"。\n"
          L"请按更像我现在想打的顺序排一下，只能使用这些候选。"
          L"如果拿不准，就尽量保持原顺序。"
          L"最多给我前 " +
          std::to_wstring(output_limit) + L" 个。";
      return prompt;
  }

  return prompt;
}

std::wstring BuildCompactPrompt(const LLMRequest& request) {
  const size_t output_limit = GetOutputLimit(request);

  switch (request.type) {
    case LLMRequestType::NoInputPrediction: {
      std::wstring prompt = L"请根据以下上下文预测接下来最可能出现的" +
                            std::to_wstring(request.max_candidates) +
                            L"个中文候选词。\n"
                            L"只返回候选词，使用空格分隔，不要解释。\n"
                            L"优先给 2 到 4 字短词；如果上下文适合，也允许 emoji 或短颜文字。"
                            L"至少包含 2 个彼此不同的短候选，避免全部都是同一前缀的改写。\n";
      prompt += L"上下文：\"" + request.context + L"\"\n";
      prompt += L"候选词：";
      return prompt;
    }
    case LLMRequestType::PinyinConstrainedPrediction: {
      std::wstring prompt = L"我在打“" + request.current_input + L"”。\n";
      if (!request.context.empty()) {
        prompt += L"前面的内容是：“" + request.context + L"”。\n";
      }
      prompt += L"请直接给我 " + std::to_wstring(request.max_candidates) +
                L" 个最自然的中文候选，每行一个。"
                L"候选必须和这个拼音对应，优先短句，不要解释。";
      return prompt;
    }
    case LLMRequestType::RimeReorder: {
      std::wstring prompt = L"请帮我把输入法候选重新排一下顺序。\n";
      if (!request.current_input.empty()) {
        prompt += L"我现在在打“" + request.current_input + L"”。\n";
      }
      if (!request.context.empty()) {
        prompt += L"前面的内容是：“" + request.context + L"”。\n";
      }
      prompt += L"现在候选有：" +
                JoinCandidatesInline(request.rime_candidates) +
                L"。\n"
                L"请按更像我现在想打的顺序回复，用空格分隔，只能用这些候选。"
                L"最多给我前 " +
                std::to_wstring(output_limit) + L" 个，不要解释。";
      return prompt;
    }
  }

  return std::wstring();
}

std::wstring BuildBaseCompletionPrompt(const LLMRequest& request) {
  switch (request.type) {
    case LLMRequestType::NoInputPrediction:
      return request.context;
    case LLMRequestType::PinyinConstrainedPrediction: {
      std::wstring prompt = request.context;
      prompt += request.current_input;
      return prompt;
    }
    case LLMRequestType::RimeReorder:
      return BuildCompactPrompt(request);
  }
  return std::wstring();
}

std::vector<std::string> BuildPinyinConstraintParts(const LLMRequest& request) {
  std::vector<std::string> constraint_parts;
  if (request.type == LLMRequestType::NoInputPrediction ||
      request.current_input.empty()) {
    return constraint_parts;
  }

  std::wstringstream ss(request.current_input);
  std::wstring part;
  while (ss >> part) {
    if (!part.empty()) {
      constraint_parts.push_back(wtou8(part));
    }
  }
  if (constraint_parts.empty()) {
    constraint_parts.push_back(wtou8(request.current_input));
  }
  return constraint_parts;
}

}  // namespace llm_request

OpenAICompatibleProvider::OpenAICompatibleProvider()
    : m_enabled(false),
      m_max_tokens(10),
      m_temperature(0.7),
      m_top_p(1.0),
      m_presence_penalty(0.0),
      m_frequency_penalty(0.0),
      m_has_seed(false),
      m_seed(0),
      m_extra_body_json(""),
      m_hSession(nullptr),
      m_hConnect(nullptr) {}

OpenAICompatibleProvider::~OpenAICompatibleProvider() {
  CloseConnection();
}

void OpenAICompatibleProvider::CloseConnection() {
  if (m_hConnect) {
    WinHttpCloseHandle((HINTERNET)m_hConnect);
    m_hConnect = nullptr;
  }
  if (m_hSession) {
    WinHttpCloseHandle((HINTERNET)m_hSession);
    m_hSession = nullptr;
  }
  m_cached_url.clear();
}

bool OpenAICompatibleProvider::LoadConfig(const std::string& config_name) {
  extern DevConsole* g_dev_console;

  // 硬编码测试配置（用于测试）
  // 注意：如果设置为 true，将不会读取yaml配置文件
  bool use_hardcoded_config =
      false;  // 设置为 true 使用硬编码配置，false 使用配置文件

  if (use_hardcoded_config) {
    if (g_dev_console && g_dev_console->IsEnabled()) {
      g_dev_console->WriteLine(L"[LLM] 使用硬编码测试配置");
    }
    m_enabled = true;
    m_api_url = "http://localhost:11434/v1/chat/completions";
    m_api_key = "";
    m_model = "qwen3:8b";
    m_max_tokens = 10;
    m_temperature = 0.7;
    m_top_p = 1.0;
    m_presence_penalty = 0.0;
    m_frequency_penalty = 0.0;
    m_has_seed = false;
    m_seed = 0;
    m_extra_body_json.clear();
    m_extra_headers.clear();
    if (g_dev_console && g_dev_console->IsEnabled()) {
      g_dev_console->WriteLine(L"[LLM] LoadConfig: llm/enabled = true");
      g_dev_console->WriteLine(L"[LLM] LoadConfig: api_url = " +
                               u8tow(m_api_url));
      g_dev_console->WriteLine(L"[LLM] LoadConfig: model = " + u8tow(m_model));
      g_dev_console->WriteLine(L"[LLM] LoadConfig: max_tokens = " +
                               std::to_wstring(m_max_tokens));
      g_dev_console->WriteLine(L"[LLM] LoadConfig: temperature = " +
                               std::to_wstring(m_temperature));
      g_dev_console->WriteLine(L"[LLM] LoadConfig: 配置加载成功（硬编码）");
    }
    CloseConnection();  // URL 可能变化，下次请求时重建连接
    return true;
  }

  RimeApi* rime_api = rime_get_api();
  if (!rime_api) {
    if (g_dev_console && g_dev_console->IsEnabled()) {
      g_dev_console->WriteLine(L"[LLM] LoadConfig失败: rime_api未初始化");
      g_dev_console->WriteLine(
          L"[LLM] 可能原因: Rime API在LoadConfig之前未正确初始化");
    }
    return false;
  }

  if (g_dev_console && g_dev_console->IsEnabled()) {
    g_dev_console->WriteLine(L"[LLM] 开始从配置文件加载: " +
                             u8tow(config_name));
  }

  RimeConfig config = {NULL};
  if (!rime_api->config_open(config_name.c_str(), &config)) {
    if (g_dev_console && g_dev_console->IsEnabled()) {
      std::wstring config_name_w = u8tow(config_name);
      g_dev_console->WriteLine(L"[LLM] LoadConfig失败: 无法打开配置文件 " +
                               config_name_w);
      g_dev_console->WriteLine(L"[LLM] 可能原因:");
      g_dev_console->WriteLine(
          L"[LLM]   1. 配置文件不存在: weasel.yaml 或 weasel.custom.yaml");
      g_dev_console->WriteLine(L"[LLM]   2. 配置文件路径错误");
      g_dev_console->WriteLine(L"[LLM]   3. 配置文件格式错误（YAML语法错误）");
      g_dev_console->WriteLine(L"[LLM]   4. Rime未正确初始化");
    }
    return false;
  }

  if (g_dev_console && g_dev_console->IsEnabled()) {
    g_dev_console->WriteLine(L"[LLM] 配置文件打开成功，开始读取配置项");
  }

  // 读取LLM配置
  Bool enabled = false;
  bool found_enabled =
      rime_api->config_get_bool(&config, "llm/enabled", &enabled);

  if (g_dev_console && g_dev_console->IsEnabled()) {
    if (found_enabled) {
      g_dev_console->WriteLine(L"[LLM] 找到配置项 llm/enabled = " +
                               std::wstring(enabled ? L"true" : L"false"));
    } else {
      g_dev_console->WriteLine(L"[LLM] 未找到配置项 llm/enabled");
      g_dev_console->WriteLine(L"[LLM] 尝试读取的路径: llm/enabled");
    }
  }

  if (found_enabled) {
    m_enabled = !!enabled;
  } else {
    m_enabled = false;
    if (g_dev_console && g_dev_console->IsEnabled()) {
      g_dev_console->WriteLine(
          L"[LLM] LoadConfig失败: 未找到配置项 llm/enabled");
      g_dev_console->WriteLine(L"[LLM] 请在配置文件中添加：");
      g_dev_console->WriteLine(L"[LLM]   llm:");
      g_dev_console->WriteLine(L"[LLM]     enabled: true");
      g_dev_console->WriteLine(
          L"[LLM] 配置文件位置通常在: %APPDATA%\\Rime\\weasel.yaml");
    }
    rime_api->config_close(&config);
    return false;
  }

  if (!m_enabled) {
    if (g_dev_console && g_dev_console->IsEnabled()) {
      g_dev_console->WriteLine(L"[LLM] LoadConfig失败: llm/enabled 为 false");
      g_dev_console->WriteLine(
          L"[LLM] 请将配置文件中的 llm/enabled 设置为 true");
    }
    rime_api->config_close(&config);
    return false;
  }

  // 读取OpenAI配置
  const int BUF_SIZE = 512;
  char buffer[BUF_SIZE + 1] = {0};

  bool found_api_url = rime_api->config_get_string(
      &config, "llm/openai/api_url", buffer, BUF_SIZE);
  if (found_api_url) {
    m_api_url = buffer;
    if (g_dev_console && g_dev_console->IsEnabled()) {
      g_dev_console->WriteLine(L"[LLM] 找到配置项 llm/openai/api_url = " +
                               u8tow(m_api_url));
    }
  } else {
    m_api_url = "https://api.openai.com/v1/chat/completions";
    if (g_dev_console && g_dev_console->IsEnabled()) {
      g_dev_console->WriteLine(
          L"[LLM] 未找到配置项 llm/openai/api_url，使用默认值 = " +
          u8tow(m_api_url));
      g_dev_console->WriteLine(
          L"[LLM] 建议在配置文件中添加: llm/openai/api_url");
    }
  }

  // api_key是可选的，对于本地服务（如Ollama）可以为空
  bool found_api_key = rime_api->config_get_string(
      &config, "llm/openai/api_key", buffer, BUF_SIZE);
  if (found_api_key) {
    m_api_key = buffer;
    if (g_dev_console && g_dev_console->IsEnabled()) {
      if (m_api_key.empty()) {
        g_dev_console->WriteLine(
            L"[LLM] 找到配置项 llm/openai/api_key = "
            L"(空，适用于本地服务如Ollama)");
      } else {
        // 只显示前8个字符，保护隐私
        std::wstring key_preview =
            m_api_key.length() > 8 ? (u8tow(m_api_key.substr(0, 8)) + L"...")
                                   : u8tow(m_api_key);
        g_dev_console->WriteLine(L"[LLM] 找到配置项 llm/openai/api_key = " +
                                 key_preview);
      }
    }
  } else {
    // api_key未配置，使用空字符串（适用于本地服务）
    m_api_key = "";
    if (g_dev_console && g_dev_console->IsEnabled()) {
      g_dev_console->WriteLine(
          L"[LLM] 未找到配置项 "
          L"llm/openai/api_key，使用空字符串（适用于本地服务如Ollama）");
    }
  }

  bool found_model = rime_api->config_get_string(&config, "llm/openai/model",
                                                 buffer, BUF_SIZE);
  if (found_model) {
    m_model = buffer;
    if (g_dev_console && g_dev_console->IsEnabled()) {
      g_dev_console->WriteLine(L"[LLM] 找到配置项 llm/openai/model = " +
                               u8tow(m_model));
    }
  } else {
    m_model = "gpt-3.5-turbo";
    if (g_dev_console && g_dev_console->IsEnabled()) {
      g_dev_console->WriteLine(
          L"[LLM] 未找到配置项 llm/openai/model，使用默认值 = " +
          u8tow(m_model));
    }
  }

  int max_tokens = 10;
  if (rime_api->config_get_int(&config, "llm/openai/max_tokens", &max_tokens)) {
    m_max_tokens = max_tokens;
    if (g_dev_console && g_dev_console->IsEnabled()) {
      g_dev_console->WriteLine(L"[LLM] LoadConfig: max_tokens = " +
                               std::to_wstring(m_max_tokens));
    }
  } else {
    if (g_dev_console && g_dev_console->IsEnabled()) {
      g_dev_console->WriteLine(L"[LLM] LoadConfig: 使用默认 max_tokens = " +
                               std::to_wstring(m_max_tokens));
    }
  }

  // Rime API可能不支持config_get_double，使用字符串读取然后转换
  char temp_str[64] = {0};
  if (rime_api->config_get_string(&config, "llm/openai/temperature", temp_str,
                                  sizeof(temp_str) - 1)) {
    m_temperature = atof(temp_str);
    if (g_dev_console && g_dev_console->IsEnabled()) {
      g_dev_console->WriteLine(L"[LLM] LoadConfig: temperature = " +
                               std::to_wstring(m_temperature));
    }
  } else {
    m_temperature = 0.7;
    if (g_dev_console && g_dev_console->IsEnabled()) {
      g_dev_console->WriteLine(L"[LLM] LoadConfig: 使用默认 temperature = " +
                               std::to_wstring(m_temperature));
    }
  }

  m_extra_body_json.clear();
  if (weasel::config_json::SerializeConfigMapToJsonObject(
          rime_api, &config, "llm/openai/extra_body", m_extra_body_json)) {
    if (g_dev_console && g_dev_console->IsEnabled()) {
      g_dev_console->WriteLine(L"[LLM] LoadConfig: extra_body = " +
                               u8tow(m_extra_body_json));
    }
  }

  m_extra_headers.clear();
  if (weasel::config_json::LoadConfigStringMap(
          rime_api, &config, "llm/openai/extra_headers", m_extra_headers)) {
    if (g_dev_console && g_dev_console->IsEnabled() &&
        !m_extra_headers.empty()) {
      std::wstring headers_summary;
      for (size_t i = 0; i < m_extra_headers.size(); ++i) {
        if (i > 0) {
          headers_summary += L", ";
        }
        headers_summary += u8tow(m_extra_headers[i].first) + L"=" +
                           u8tow(m_extra_headers[i].second);
      }
      g_dev_console->WriteLine(L"[LLM] LoadConfig: extra_headers = " +
                               headers_summary);
    }
  }

  // 读取可选额外参数（有配置则生效，无配置则使用默认值）
  if (rime_api->config_get_string(&config, "llm/openai/top_p", temp_str,
                                  sizeof(temp_str) - 1)) {
    m_top_p = atof(temp_str);
  } else {
    m_top_p = 1.0;
  }

  if (rime_api->config_get_string(&config, "llm/openai/presence_penalty",
                                  temp_str, sizeof(temp_str) - 1)) {
    m_presence_penalty = atof(temp_str);
  } else {
    m_presence_penalty = 0.0;
  }

  if (rime_api->config_get_string(&config, "llm/openai/frequency_penalty",
                                  temp_str, sizeof(temp_str) - 1)) {
    m_frequency_penalty = atof(temp_str);
  } else {
    m_frequency_penalty = 0.0;
  }

  int seed = 0;
  if (rime_api->config_get_int(&config, "llm/openai/seed", &seed)) {
    m_seed = seed;
    m_has_seed = true;
  } else {
    m_seed = 0;
    m_has_seed = false;
  }

  if (g_dev_console && g_dev_console->IsEnabled()) {
    g_dev_console->WriteLine(L"[LLM] LoadConfig: top_p = " +
                             std::to_wstring(m_top_p));
    g_dev_console->WriteLine(L"[LLM] LoadConfig: presence_penalty = " +
                             std::to_wstring(m_presence_penalty));
    g_dev_console->WriteLine(L"[LLM] LoadConfig: frequency_penalty = " +
                             std::to_wstring(m_frequency_penalty));
    g_dev_console->WriteLine(
        L"[LLM] LoadConfig: seed = " +
        std::wstring(m_has_seed ? std::to_wstring(m_seed) : L"(未设置)"));
  }

  // 任意 JSON 透传（必须是 JSON 对象字符串，如 {"stream":false,"user":"abc"}）
  if (rime_api->config_get_string(&config, "llm/openai/extra_body_json", buffer,
                                  BUF_SIZE)) {
    m_extra_body_json = buffer;
  } else {
    m_extra_body_json.clear();
  }
  if (g_dev_console && g_dev_console->IsEnabled()) {
    g_dev_console->WriteLine(
        L"[LLM] LoadConfig: extra_body_json = " +
        std::wstring(m_extra_body_json.empty() ? L"(空)" : u8tow(m_extra_body_json)));
  }

  CloseConnection();  // URL 可能变化，下次请求时重建连接
  rime_api->config_close(&config);

  if (g_dev_console && g_dev_console->IsEnabled()) {
    g_dev_console->WriteLine(L"[LLM] LoadConfig: 配置加载成功");
  }

  return true;
}

std::vector<std::wstring> OpenAICompatibleProvider::ExecuteRequest(
    const LLMRequest& request,
    const LLMPartialCallback& on_partial) {
  std::vector<std::wstring> candidates;

  if (!IsAvailable() || !llm_request::IsExecutable(request)) {
    return candidates;
  }

  const bool is_local_ollama =
      m_api_url.find("127.0.0.1:11434") != std::string::npos ||
      m_api_url.find("localhost:11434") != std::string::npos;
  if (is_local_ollama && request.type == LLMRequestType::NoInputPrediction) {
    const std::string prompt_utf8 = wtou8(request.context);
    const std::string generate_url =
        m_api_url.find("/v1/chat/completions") != std::string::npos
            ? m_api_url.substr(0, m_api_url.find("/v1/chat/completions")) +
                  "/api/generate"
            : "http://127.0.0.1:11434/api/generate";
    const double low_temperature =
        (std::max)(0.08, (std::min)(m_temperature, 0.22));
    const double high_temperature =
        (std::min)(1.0, (std::max)(m_temperature, 0.82));

    struct OllamaContinuationBranchSpec {
      const wchar_t* label;
      double temperature;
      int num_predict;
      size_t max_candidate_chars;
      const wchar_t* stop_chars;
      bool allow_stream_partial;
      size_t partial_visible_limit;
    };

    const std::vector<OllamaContinuationBranchSpec> branch_specs = {
        {L"首候选", low_temperature, 8, 8, L"\r\n。！？!?；;，,、 ", true, 1},
        {L"高多样短词", high_temperature, 8, 3, L"\r\n。！？!?；;，,、 ", false,
         2},
        {L"高多样短语", (std::min)(1.0, high_temperature + 0.08), 12, 4,
         L"\r\n。！？!?；;，,、 ", false, 2},
        {L"补充短语", (low_temperature + high_temperature) / 2.0, 20, 8,
         L"\r\n。！？!?；;，,、", false, 2},
        {L"补充长句", high_temperature, 48, 24, L"\r\n。！？!?；;", false, 3},
    };

    auto build_generate_body = [&](double temperature, int num_predict) {
      std::ostringstream json;
      json << "{"
           << "\"model\":\"" << weasel::config_json::EscapeJsonString(m_model)
           << "\","
           << "\"prompt\":\""
           << weasel::config_json::EscapeJsonString(prompt_utf8) << "\","
           << "\"stream\":true,"
           << "\"raw\":true,"
           << "\"think\":false,"
           << "\"options\":{"
           << "\"temperature\":" << temperature << ","
           << "\"num_predict\":" << num_predict << "}"
           << "}";
      return json.str();
    };

    extern DevConsole* g_dev_console;
    if (g_dev_console && g_dev_console->IsEnabled()) {
      g_dev_console->WriteLine(
          L"[LLM] 发送请求（Ollama Generate / continuation）");
      g_dev_console->WriteLine(L"  请求类型: " +
                               llm_request::GetRequestTypeName(request.type));
      g_dev_console->WriteLine(L"  原始上下文: " + request.context);
      g_dev_console->WriteLine(L"  请求URL: " + u8tow(generate_url));
      for (const auto& branch : branch_specs) {
        std::wstringstream ss;
        ss << L"  " << branch.label << L": temperature=" << branch.temperature
           << L", num_predict=" << branch.num_predict
           << L", max_candidate_chars=" << branch.max_candidate_chars
           << L", stream_partial="
           << (branch.allow_stream_partial ? L"true" : L"false");
        g_dev_console->WriteLine(ss.str());
      }
    }

    auto merge_candidate_set = [&](const std::vector<std::wstring>& incoming) {
      bool changed = false;
      for (const auto& candidate : incoming) {
        if (candidate.empty()) {
          continue;
        }
        if (std::find(candidates.begin(), candidates.end(), candidate) !=
            candidates.end()) {
          continue;
        }
        candidates.push_back(candidate);
        changed = true;
      }
      return changed;
    };

    auto publish_candidates = [&]() {
      if (!on_partial || candidates.empty()) {
        return true;
      }
      std::vector<std::wstring> visible_candidates =
          ReorderCandidatesForNoInputDiversity(candidates, request.max_candidates);
      if (request.max_candidates > 0 &&
          visible_candidates.size() > request.max_candidates) {
        visible_candidates.resize(request.max_candidates);
      }
      return on_partial(visible_candidates);
    };

    for (size_t branch_index = 0; branch_index < branch_specs.size();
         ++branch_index) {
      const auto& branch = branch_specs[branch_index];
      const std::string branch_body =
          build_generate_body(branch.temperature, branch.num_predict);
      std::string branch_response_body;
      LLMPartialCallback branch_partial_callback;
      if (branch.allow_stream_partial && on_partial) {
        branch_partial_callback =
            [on_partial](const std::vector<std::wstring>& partial_candidates) {
              return on_partial(partial_candidates);
            };
      }
      if (!ExecuteOllamaGenerateRequest(generate_url, branch_body, prompt_utf8,
                                        branch.partial_visible_limit,
                                        branch_partial_callback,
                                        branch_response_body)) {
        continue;
      }

      const std::wstring generated =
          u8tow(ExtractContentFromOllamaGenerateResponse(branch_response_body));
      const size_t candidate_count_before = candidates.size();
      merge_candidate_set(BuildSingleContinuationCandidates(
          request.context, generated, 1, branch.max_candidate_chars,
          branch.stop_chars, true));
      if (candidates.size() > candidate_count_before &&
          !publish_candidates()) {
        break;
      }
      if (request.max_candidates > 0 &&
          candidates.size() >= request.max_candidates) {
        break;
      }
    }

    if (g_dev_console && g_dev_console->IsEnabled()) {
      std::wstringstream ss;
      ss << L"[LLM] continuation 多分支合并后候选数: " << candidates.size();
      g_dev_console->WriteLine(ss.str());
    }
    candidates =
        ReorderCandidatesForNoInputDiversity(candidates, request.max_candidates);
    if (request.max_candidates > 0 &&
        candidates.size() > request.max_candidates) {
      candidates.resize(request.max_candidates);
    }
    return candidates;
  }

  const llm_request::InstructPrompt prompt =
      llm_request::BuildInstructPrompt(request);
  if (prompt.system_prompt.empty() || prompt.user_prompt.empty()) {
    return candidates;
  }

  // 输出请求内容到开发终端
  extern DevConsole* g_dev_console;

  // 构建JSON请求体
  std::string system_prompt_utf8 = wtou8(prompt.system_prompt);
  std::string user_prompt_utf8 = wtou8(prompt.user_prompt);
  std::string escaped_system_prompt =
      weasel::config_json::EscapeJsonString(system_prompt_utf8);
  std::string escaped_user_prompt =
      weasel::config_json::EscapeJsonString(user_prompt_utf8);
  std::string extra_body_members = StripJsonObjectBraces(m_extra_body_json);
  std::ostringstream json;
  json << "{"
       << "\"model\":\"" << weasel::config_json::EscapeJsonString(m_model)
       << "\","
       << "\"messages\":["
       << "{\"role\":\"system\",\"content\":\"" << escaped_system_prompt
       << "\"},"
       << "{\"role\":\"user\",\"content\":\"" << escaped_user_prompt << "\"}"
       << "],"
       << "\"stream\":true,"
       << "\"max_tokens\":" << m_max_tokens << ","
       << "\"temperature\":" << m_temperature;
  const bool has_reasoning_directive =
      extra_body_members.find("\"reasoning_effort\"") != std::string::npos ||
      extra_body_members.find("\"reasoning\"") != std::string::npos;
  const bool has_think_directive =
      extra_body_members.find("\"think\"") != std::string::npos;
  const bool has_stop_directive =
      extra_body_members.find("\"stop\"") != std::string::npos;
  if (is_local_ollama && !has_reasoning_directive) {
    json << ",\"reasoning_effort\":\"none\"";
  }
  if (is_local_ollama && !has_think_directive) {
    json << ",\"think\":false";
  }
  if (is_local_ollama && !has_stop_directive &&
      request.type != LLMRequestType::NoInputPrediction) {
    json << ",\"stop\":[\"Thinking:\",\"<|im_start|>\",\"<|endoftext|>\"]";
  }
  if (!extra_body_members.empty()) {
    json << "," << extra_body_members;
  }

  json << ",\"top_p\":" << m_top_p
       << ",\"presence_penalty\":" << m_presence_penalty
       << ",\"frequency_penalty\":" << m_frequency_penalty;
  if (m_has_seed) {
    json << ",\"seed\":" << m_seed;
  }

  // 透传额外 JSON（合并对象内部字段到根对象）
  if (!m_extra_body_json.empty()) {
    size_t start = m_extra_body_json.find_first_not_of(" \t\r\n");
    size_t end = m_extra_body_json.find_last_not_of(" \t\r\n");
    if (start != std::string::npos && end != std::string::npos &&
        m_extra_body_json[start] == '{' && m_extra_body_json[end] == '}') {
      std::string inner =
          m_extra_body_json.substr(start + 1, end - start - 1);
      if (!inner.empty()) {
        json << "," << inner;
      }
    } else {
      if (g_dev_console && g_dev_console->IsEnabled()) {
        g_dev_console->WriteLine(
            L"[LLM] extra_body_json 格式无效，需为 JSON 对象字符串，已忽略");
      }
    }
  }

  json << "}";

  std::string request_body = json.str();


  if (g_dev_console && g_dev_console->IsEnabled()) {
    g_dev_console->WriteLine(L"[LLM] 发送请求（OpenAI Compatible）");
    g_dev_console->WriteLine(L"  请求类型: " +
                             llm_request::GetRequestTypeName(request.type));
    g_dev_console->WriteLine(L"  上下文: " + request.context);
    if (!request.current_input.empty()) {
      g_dev_console->WriteLine(L"  当前输入: " + request.current_input);
    }
    if (!request.rime_candidates.empty()) {
      g_dev_console->WriteLine(L"  Rime候选数: " +
                               std::to_wstring(request.rime_candidates.size()));
    }
    g_dev_console->WriteLine(L"  请求URL: " + u8tow(m_api_url));
    g_dev_console->WriteLine(L"  请求体: " + u8tow(request_body));
  }

  // 执行HTTP请求
  std::string response_body;
  if (!ExecuteHttpRequest(m_api_url, request_body, request.type,
                          request.max_candidates, on_partial,
                          response_body)) {
    if (g_dev_console && g_dev_console->IsEnabled()) {
      g_dev_console->WriteLine(L"[LLM] 请求失败");
    }
    return candidates;
  }

  // 输出响应内容到开发终端
  if (g_dev_console && g_dev_console->IsEnabled()) {
    g_dev_console->WriteLine(L"[LLM] 收到响应");
    g_dev_console->WriteLine(L"  响应内容: " + u8tow(response_body));
  }

  // 解析响应
  candidates = ParseResponse(response_body, request.type);
  if (request.type == LLMRequestType::RimeReorder) {
    const std::wstring extracted_content =
        u8tow(ExtractContentFromSseResponse(response_body));
    if (!extracted_content.empty()) {
      const std::vector<std::wstring> mentioned_candidates =
          ExtractRankedCandidatesFromTextMentions(extracted_content,
                                                  request.rime_candidates,
                                                  request.max_candidates);
      if (mentioned_candidates.size() > candidates.size()) {
        candidates = mentioned_candidates;
      }
    }
    const std::vector<std::wstring> filtered_candidates =
        FilterCandidatesAgainstPool(candidates, request.rime_candidates,
                                    request.max_candidates);
    if (filtered_candidates.size() != candidates.size() && g_dev_console &&
        g_dev_console->IsEnabled()) {
      std::wstringstream ss;
      ss << L"[LLM] 重排响应中有 "
         << (candidates.size() - filtered_candidates.size())
         << L" 个候选不在 Rime 候选池内，已丢弃";
      g_dev_console->WriteLine(ss.str());
    }
    candidates = filtered_candidates;
  }
  if (request.max_candidates > 0 &&
      candidates.size() > request.max_candidates) {
    candidates.resize(request.max_candidates);
  }

  // if (g_dev_console && g_dev_console->IsEnabled()) {
  //   std::wstringstream ss;
  //   ss << L"[LLM] 解析得到 " << candidates.size() << L" 个候选词";
  //   g_dev_console->WriteLine(ss.str());
  //   for (size_t i = 0; i < candidates.size(); ++i) {
  //     std::wstringstream ss2;
  //     ss2 << L"  " << (i + 1) << L". " << candidates[i];
  //     g_dev_console->WriteLine(ss2.str());
  //   }
  // }

  return candidates;
}

bool OpenAICompatibleProvider::IsAvailable() const {
  // api_key可以为空（适用于本地服务如Ollama），只需要enabled和api_url不为空
  return m_enabled && !m_api_url.empty();
}

bool OpenAICompatibleProvider::ExecuteHttpRequest(
    const std::string& url,
    const std::string& request_body,
    LLMRequestType request_type,
    size_t max_candidates,
    const LLMPartialCallback& on_partial,
    std::string& response_body) {
  URL_COMPONENTS url_comp = {0};
  url_comp.dwStructSize = sizeof(URL_COMPONENTS);
  url_comp.dwSchemeLength = (DWORD)-1;
  url_comp.dwHostNameLength = (DWORD)-1;
  url_comp.dwUrlPathLength = (DWORD)-1;
  url_comp.dwExtraInfoLength = (DWORD)-1;

  std::wstring url_w = u8tow(url);
  wchar_t hostname[256] = {0};
  wchar_t path[1024] = {0};
  url_comp.lpszHostName = hostname;
  url_comp.lpszUrlPath = path;

  if (!WinHttpCrackUrl(url_w.c_str(), (DWORD)url_w.length(), 0, &url_comp)) {
    return false;
  }

  INTERNET_PORT port = url_comp.nPort;
  bool use_https = (url_comp.nScheme == INTERNET_SCHEME_HTTPS);
  if (port == 0) {
    port = use_https ? INTERNET_DEFAULT_HTTPS_PORT : INTERNET_DEFAULT_HTTP_PORT;
  }

  std::wstring hostname_str(hostname, url_comp.dwHostNameLength);
  std::wstring path_str(path, url_comp.dwUrlPathLength);

  HINTERNET hSession = (HINTERNET)m_hSession;
  HINTERNET hConnect = (HINTERNET)m_hConnect;

  if (m_cached_url != url || !hSession || !hConnect) {
    CloseConnection();
    bool is_localhost =
        (hostname_str == L"localhost" || hostname_str == L"127.0.0.1");
    DWORD access_type = is_localhost ? WINHTTP_ACCESS_TYPE_NO_PROXY
                                     : WINHTTP_ACCESS_TYPE_DEFAULT_PROXY;
    hSession =
        WinHttpOpen(L"Weasel IME/1.0", access_type,
                    is_localhost ? (LPCWSTR)WINHTTP_NO_PROXY_NAME : NULL,
                    is_localhost ? (LPCWSTR)WINHTTP_NO_PROXY_BYPASS : NULL, 0);
    if (!hSession) {
      return false;
    }
    // 冷启动本地模型或较慢的 OpenAI 兼容服务首个请求可能超过 10 秒；
    // 连接阶段保持较短超时，接收阶段放宽到 60 秒，避免误判为“请求失败”。
    WinHttpSetTimeouts(hSession, 10000, 10000, 15000, 60000);
    hConnect = WinHttpConnect(hSession, hostname_str.c_str(), port, 0);
    if (!hConnect) {
      WinHttpCloseHandle(hSession);
      return false;
    }
    m_hSession = hSession;
    m_hConnect = hConnect;
    m_cached_url = url;
  }

  HINTERNET hRequest = WinHttpOpenRequest(
      hConnect, L"POST", path_str.c_str(), NULL, WINHTTP_NO_REFERER,
      WINHTTP_DEFAULT_ACCEPT_TYPES, use_https ? WINHTTP_FLAG_SECURE : 0);
  if (!hRequest) {
    CloseConnection();
    return false;
  }

  std::wstring headers;
  if (!HasHeaderNamed(m_extra_headers, "Content-Type")) {
    headers += L"Content-Type: application/json\r\n";
  }
  if (!m_api_key.empty() && !HasHeaderNamed(m_extra_headers, "Authorization")) {
    std::wstring api_key_w = u8tow(m_api_key);
    headers += L"Authorization: Bearer " + api_key_w + L"\r\n";
  }
  for (const auto& header : m_extra_headers) {
    headers += u8tow(header.first) + L": " + u8tow(header.second) + L"\r\n";
  }

  if (!WinHttpSendRequest(
          hRequest, headers.c_str(), (DWORD)-1, (LPVOID)request_body.c_str(),
          (DWORD)request_body.length(), (DWORD)request_body.length(), 0)) {
    WinHttpCloseHandle(hRequest);
    CloseConnection();
    return false;
  }

  if (!WinHttpReceiveResponse(hRequest, NULL)) {
    WinHttpCloseHandle(hRequest);
    CloseConnection();
    return false;
  }

  DWORD bytes_available = 0;
  response_body.clear();
  std::string stream_buffer;
  std::string aggregated_content;
  std::vector<std::wstring> last_partial_candidates;
  while (WinHttpQueryDataAvailable(hRequest, &bytes_available) &&
         bytes_available > 0) {
    std::vector<char> buffer(bytes_available);
    DWORD bytes_read = 0;
    if (WinHttpReadData(hRequest, buffer.data(), bytes_available,
                        &bytes_read)) {
      response_body.append(buffer.data(), bytes_read);
      stream_buffer.append(buffer.data(), bytes_read);
      size_t newline_pos = std::string::npos;
      while ((newline_pos = stream_buffer.find('\n')) != std::string::npos) {
        std::string line = stream_buffer.substr(0, newline_pos);
        stream_buffer.erase(0, newline_pos + 1);
        if (!line.empty() && line.back() == '\r') {
          line.pop_back();
        }
        if (line.empty() || line.rfind("data: ", 0) != 0) {
          continue;
        }

        const std::string payload = line.substr(6);
        if (payload == "[DONE]") {
          WinHttpCloseHandle(hRequest);
          return !response_body.empty();
        }

        std::string delta_content;
        bool finished = false;
        if (!ExtractContentFromOpenAIChunkPayload(payload, delta_content,
                                                  finished)) {
          continue;
        }
        if (!delta_content.empty()) {
          aggregated_content += delta_content;
          if (on_partial) {
            std::vector<std::wstring> partial_candidates =
                ExtractCandidatesFromUtf8Text(
                    aggregated_content, max_candidates,
                    request_type == LLMRequestType::NoInputPrediction);
            if (!partial_candidates.empty() &&
                partial_candidates != last_partial_candidates) {
              last_partial_candidates = partial_candidates;
              if (!on_partial(partial_candidates)) {
                WinHttpCloseHandle(hRequest);
                return !response_body.empty();
              }
            }
          }
        }
        if (finished) {
          WinHttpCloseHandle(hRequest);
          return !response_body.empty();
        }
      }
    } else {
      break;
    }
  }

  WinHttpCloseHandle(hRequest);
  return !response_body.empty();
}

bool OpenAICompatibleProvider::ExecuteOllamaGenerateRequest(
    const std::string& url,
    const std::string& request_body,
    const std::string& prompt_prefix_utf8,
    size_t max_candidates,
    const LLMPartialCallback& on_partial,
    std::string& response_body) {
  URL_COMPONENTS url_comp = {0};
  url_comp.dwStructSize = sizeof(URL_COMPONENTS);
  url_comp.dwSchemeLength = (DWORD)-1;
  url_comp.dwHostNameLength = (DWORD)-1;
  url_comp.dwUrlPathLength = (DWORD)-1;
  url_comp.dwExtraInfoLength = (DWORD)-1;

  std::wstring url_w = u8tow(url);
  wchar_t hostname[256] = {0};
  wchar_t path[1024] = {0};
  url_comp.lpszHostName = hostname;
  url_comp.lpszUrlPath = path;

  if (!WinHttpCrackUrl(url_w.c_str(), (DWORD)url_w.length(), 0, &url_comp)) {
    return false;
  }

  INTERNET_PORT port = url_comp.nPort;
  bool use_https = (url_comp.nScheme == INTERNET_SCHEME_HTTPS);
  if (port == 0) {
    port = use_https ? INTERNET_DEFAULT_HTTPS_PORT : INTERNET_DEFAULT_HTTP_PORT;
  }

  std::wstring hostname_str(hostname, url_comp.dwHostNameLength);
  std::wstring path_str(path, url_comp.dwUrlPathLength);
  const bool is_localhost =
      (hostname_str == L"localhost" || hostname_str == L"127.0.0.1");

  HINTERNET hSession =
      WinHttpOpen(L"Weasel IME/1.0",
                  is_localhost ? WINHTTP_ACCESS_TYPE_NO_PROXY
                               : WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                  is_localhost ? (LPCWSTR)WINHTTP_NO_PROXY_NAME : NULL,
                  is_localhost ? (LPCWSTR)WINHTTP_NO_PROXY_BYPASS : NULL, 0);
  if (!hSession) {
    return false;
  }
  WinHttpSetTimeouts(hSession, 10000, 10000, 15000, 60000);

  HINTERNET hConnect = WinHttpConnect(hSession, hostname_str.c_str(), port, 0);
  if (!hConnect) {
    WinHttpCloseHandle(hSession);
    return false;
  }

  HINTERNET hRequest = WinHttpOpenRequest(
      hConnect, L"POST", path_str.c_str(), NULL, WINHTTP_NO_REFERER,
      WINHTTP_DEFAULT_ACCEPT_TYPES, use_https ? WINHTTP_FLAG_SECURE : 0);
  if (!hRequest) {
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
    return false;
  }

  const std::wstring headers = L"Content-Type: application/json\r\n";
  if (!WinHttpSendRequest(
          hRequest, headers.c_str(), (DWORD)-1, (LPVOID)request_body.c_str(),
          (DWORD)request_body.length(), (DWORD)request_body.length(), 0)) {
    WinHttpCloseHandle(hRequest);
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
    return false;
  }

  if (!WinHttpReceiveResponse(hRequest, NULL)) {
    WinHttpCloseHandle(hRequest);
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
    return false;
  }

  DWORD bytes_available = 0;
  response_body.clear();
  std::string line_buffer;
  std::string aggregated_content;
  std::vector<std::wstring> last_partial_candidates;
  const std::wstring prompt_prefix = u8tow(prompt_prefix_utf8);

  while (WinHttpQueryDataAvailable(hRequest, &bytes_available) &&
         bytes_available > 0) {
    std::vector<char> buffer(bytes_available);
    DWORD bytes_read = 0;
    if (!WinHttpReadData(hRequest, buffer.data(), bytes_available,
                         &bytes_read)) {
      break;
    }
    response_body.append(buffer.data(), bytes_read);
    line_buffer.append(buffer.data(), bytes_read);

    size_t newline_pos = std::string::npos;
    while ((newline_pos = line_buffer.find('\n')) != std::string::npos) {
      std::string line = line_buffer.substr(0, newline_pos);
      line_buffer.erase(0, newline_pos + 1);
      if (!line.empty() && line.back() == '\r') {
        line.pop_back();
      }
      if (line.empty()) {
        continue;
      }

      std::string delta_content;
      bool finished = false;
      if (!ExtractResponseFromOllamaGenerateChunkPayload(line, delta_content,
                                                         finished)) {
        continue;
      }
      if (!delta_content.empty()) {
        aggregated_content += delta_content;
        if (on_partial) {
          std::vector<std::wstring> partial_candidates =
              BuildContinuationCandidates(
                  prompt_prefix, u8tow(aggregated_content), max_candidates,
                  true);
          if (!partial_candidates.empty() &&
              partial_candidates != last_partial_candidates) {
            last_partial_candidates = partial_candidates;
            if (!on_partial(partial_candidates)) {
              WinHttpCloseHandle(hRequest);
              WinHttpCloseHandle(hConnect);
              WinHttpCloseHandle(hSession);
              return !response_body.empty();
            }
          }
        }
      }
      if (finished) {
        WinHttpCloseHandle(hRequest);
        WinHttpCloseHandle(hConnect);
        WinHttpCloseHandle(hSession);
        return !response_body.empty();
      }
    }
  }

  WinHttpCloseHandle(hRequest);
  WinHttpCloseHandle(hConnect);
  WinHttpCloseHandle(hSession);
  return !response_body.empty();
}

std::vector<std::wstring> OpenAICompatibleProvider::ParseResponse(
    const std::string& json_response,
    LLMRequestType request_type) {
  const bool allow_expressive_tokens =
      request_type == LLMRequestType::NoInputPrediction;
  if (json_response.find("data: ") != std::string::npos) {
    return ExtractCandidatesFromUtf8Text(
        ExtractContentFromSseResponse(json_response), 0,
        allow_expressive_tokens);
  }

  std::string content;
  try {
    boost::property_tree::ptree root;
    std::istringstream json_stream(json_response);
    boost::property_tree::read_json(json_stream, root);

    const char* field_names[] = {"content", "text", "generated_text",
                                 "responses"};
    for (const char* field_name : field_names) {
      if (FindFirstStringFieldByName(root, field_name, content)) {
        break;
      }
    }
  } catch (const boost::property_tree::json_parser_error&) {
    return {};
  }

  if (content.empty()) {
    return {};
  }
  return ExtractCandidatesFromUtf8Text(content, 0, allow_expressive_tokens);
}

// 全局开发终端实例（供LLMProvider使用）
DevConsole* g_dev_console = nullptr;
