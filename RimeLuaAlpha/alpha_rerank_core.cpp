#include <windows.h>

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

extern "C" {

struct lua_State;
using lua_Integer = long long;
using lua_Number = double;
using lua_CFunction = int (*)(lua_State* L);

struct luaL_Reg {
  const char* name;
  lua_CFunction func;
};

const lua_Number* lua_version(lua_State* L);
void lua_createtable(lua_State* L, int narr, int nrec);
int lua_getfield(lua_State* L, int idx, const char* k);
int lua_geti(lua_State* L, int idx, lua_Integer n);
int lua_gettop(lua_State* L);
void lua_pushboolean(lua_State* L, int b);
void lua_pushcclosure(lua_State* L, lua_CFunction fn, int n);
void lua_pushinteger(lua_State* L, lua_Integer n);
void lua_pushnil(lua_State* L);
void lua_pushnumber(lua_State* L, lua_Number n);
const char* lua_pushstring(lua_State* L, const char* s);
void lua_setfield(lua_State* L, int idx, const char* k);
void lua_seti(lua_State* L, int idx, lua_Integer n);
void lua_settop(lua_State* L, int idx);
int lua_type(lua_State* L, int idx);
const char* lua_tolstring(lua_State* L, int idx, size_t* len);
int lua_toboolean(lua_State* L, int idx);
lua_Integer lua_tointegerx(lua_State* L, int idx, int* isnum);
size_t lua_rawlen(lua_State* L, int idx);

void luaL_checktype(lua_State* L, int arg, int t);
const char* luaL_checklstring(lua_State* L, int arg, size_t* len);
void luaL_checkversion_(lua_State* L, lua_Number ver, size_t sz);
int luaL_error(lua_State* L, const char* fmt, ...);
void luaL_setfuncs(lua_State* L, const luaL_Reg* l, int nup);

}  // extern "C"

namespace {

constexpr int kLuaTypeNil = 0;
constexpr int kLuaTypeBoolean = 1;
constexpr int kLuaTypeNumber = 3;
constexpr int kLuaTypeString = 4;
constexpr int kLuaTypeTable = 5;
constexpr size_t kLuaNumSizes =
    sizeof(lua_Integer) * 16 + sizeof(lua_Number);

#define lua_pop(L, n) lua_settop((L), -(n)-1)
#define lua_newtable(L) lua_createtable((L), 0, 0)
#define luaL_newlib(L, l)                             \
  do {                                               \
    lua_createtable((L), 0, sizeof(l) / sizeof((l)[0]) - 1); \
    luaL_setfuncs((L), (l), 0);                      \
  } while (0)

struct SimilarityResult {
  char* word;
  float score;
};

using AlphaPredictiveHandle = void*;
using AlphaPredictiveNewFn = AlphaPredictiveHandle(__cdecl*)(const char*);
using AlphaPredictiveFreeFn = void(__cdecl*)(AlphaPredictiveHandle);
using AlphaPredictiveComputeOrderedFn = int(__cdecl*)(
    AlphaPredictiveHandle,
    const char*,
    const char* const*,
    int,
    SimilarityResult**);
using AlphaPredictiveApplyFeedbackFn = int(__cdecl*)(
    AlphaPredictiveHandle,
    const char*,
    const char* const*,
    int);
using AlphaPredictiveUpdatePreferenceFn =
    int(__cdecl*)(AlphaPredictiveHandle, const char*);
using AlphaPredictiveFreeResultFn =
    void(__cdecl*)(SimilarityResult*, int);

struct AlphaLibrary {
  HMODULE module = nullptr;
  AlphaPredictiveNewFn create = nullptr;
  AlphaPredictiveFreeFn destroy = nullptr;
  AlphaPredictiveComputeOrderedFn compute_ordered = nullptr;
  AlphaPredictiveApplyFeedbackFn apply_feedback = nullptr;
  AlphaPredictiveUpdatePreferenceFn update_preference = nullptr;
  AlphaPredictiveFreeResultFn free_result = nullptr;
  AlphaPredictiveHandle predictor = nullptr;
  std::wstring module_dir;
  std::wstring library_path;
  std::string config_path_utf8;
};

AlphaLibrary g_alpha;
std::mutex g_alpha_mutex;
HMODULE g_self_module = nullptr;

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int len = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                                      static_cast<int>(utf8.size()), nullptr, 0);
  if (len <= 0) {
    return std::wstring();
  }
  std::wstring wide(len, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()),
                      wide.data(), len);
  return wide;
}

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) {
    return std::string();
  }
  const int len = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                                      static_cast<int>(wide.size()), nullptr, 0,
                                      nullptr, nullptr);
  if (len <= 0) {
    return std::string();
  }
  std::string utf8(len, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()),
                      utf8.data(), len, nullptr, nullptr);
  return utf8;
}

std::wstring GetLastWin32ErrorMessage(DWORD error_code) {
  LPWSTR buffer = nullptr;
  const DWORD size = FormatMessageW(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
          FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, error_code, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
      reinterpret_cast<LPWSTR>(&buffer), 0, nullptr);
  std::wstring message;
  if (size > 0 && buffer) {
    message.assign(buffer, size);
    while (!message.empty() &&
           (message.back() == L'\r' || message.back() == L'\n' ||
            message.back() == L' ' || message.back() == L'\t')) {
      message.pop_back();
    }
  }
  if (buffer) {
    LocalFree(buffer);
  }
  return message;
}

std::string WideMessageToUtf8(const std::wstring& message) {
  return message.empty() ? std::string("unknown error") : WideToUtf8(message);
}

std::wstring GetDllDirectory(HMODULE module) {
  wchar_t path[MAX_PATH] = {0};
  const DWORD len = GetModuleFileNameW(module, path, MAX_PATH);
  if (len == 0 || len >= MAX_PATH) {
    return std::wstring();
  }
  return std::filesystem::path(path).parent_path().wstring();
}

void ResetPredictorUnlocked() {
  if (g_alpha.predictor && g_alpha.destroy) {
    g_alpha.destroy(g_alpha.predictor);
    g_alpha.predictor = nullptr;
  }
}

void ResetLibraryUnlocked() {
  ResetPredictorUnlocked();
  if (g_alpha.module) {
    FreeLibrary(g_alpha.module);
    g_alpha.module = nullptr;
  }
  g_alpha.create = nullptr;
  g_alpha.destroy = nullptr;
  g_alpha.compute_ordered = nullptr;
  g_alpha.apply_feedback = nullptr;
  g_alpha.update_preference = nullptr;
  g_alpha.free_result = nullptr;
  g_alpha.library_path.clear();
}

int PushNilError(lua_State* L, const std::string& error) {
  lua_pushnil(L);
  lua_pushstring(L, error.c_str());
  return 2;
}

std::string LuaCheckString(lua_State* L, int index) {
  size_t len = 0;
  const char* value = luaL_checklstring(L, index, &len);
  return value ? std::string(value, len) : std::string();
}

std::string LuaGetOptionalStringField(lua_State* L,
                                      int table_index,
                                      const char* field_name) {
  lua_getfield(L, table_index, field_name);
  std::string value;
  if (lua_type(L, -1) == kLuaTypeString) {
    size_t len = 0;
    const char* raw = lua_tolstring(L, -1, &len);
    if (raw) {
      value.assign(raw, len);
    }
  }
  lua_pop(L, 1);
  return value;
}

int LuaGetOptionalIntegerField(lua_State* L,
                               int table_index,
                               const char* field_name,
                               int default_value) {
  lua_getfield(L, table_index, field_name);
  int value = default_value;
  if (lua_type(L, -1) == kLuaTypeNumber) {
    int is_num = 0;
    value = static_cast<int>(lua_tointegerx(L, -1, &is_num));
    if (!is_num) {
      value = default_value;
    }
  }
  lua_pop(L, 1);
  return value;
}

std::wstring ResolveLibraryPath(const std::string& dll_path_utf8) {
  if (!dll_path_utf8.empty()) {
    std::filesystem::path dll_path = Utf8ToWide(dll_path_utf8);
    if (!dll_path.is_absolute() && !g_alpha.module_dir.empty()) {
      dll_path = std::filesystem::path(g_alpha.module_dir) / dll_path;
    }
    return dll_path.lexically_normal().wstring();
  }

  if (!g_alpha.module_dir.empty()) {
    return (std::filesystem::path(g_alpha.module_dir) / L"alpha_input.dll")
        .wstring();
  }
  return L"alpha_input.dll";
}

bool LoadAlphaLibraryUnlocked(const std::wstring& library_path,
                              std::string& error) {
  if (g_alpha.module && g_alpha.library_path == library_path &&
      g_alpha.create && g_alpha.destroy && g_alpha.compute_ordered &&
      g_alpha.free_result) {
    return true;
  }

  ResetLibraryUnlocked();

  HMODULE module = LoadLibraryExW(
      library_path.c_str(), nullptr,
      LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
  if (!module) {
    module = LoadLibraryW(library_path.c_str());
  }
  if (!module) {
    std::ostringstream ss;
    ss << "failed to load alpha_input.dll from "
       << WideToUtf8(library_path) << ": "
       << WideMessageToUtf8(GetLastWin32ErrorMessage(GetLastError()));
    error = ss.str();
    return false;
  }

  auto create = reinterpret_cast<AlphaPredictiveNewFn>(
      GetProcAddress(module, "alpha_predictive_new"));
  auto destroy = reinterpret_cast<AlphaPredictiveFreeFn>(
      GetProcAddress(module, "alpha_predictive_free"));
  auto compute = reinterpret_cast<AlphaPredictiveComputeOrderedFn>(
      GetProcAddress(module, "alpha_predictive_compute_similarities_ordered"));
  auto apply_feedback = reinterpret_cast<AlphaPredictiveApplyFeedbackFn>(
      GetProcAddress(module, "alpha_predictive_apply_user_feedback"));
  auto update_preference = reinterpret_cast<AlphaPredictiveUpdatePreferenceFn>(
      GetProcAddress(module, "alpha_predictive_update_user_preference"));
  auto free_result = reinterpret_cast<AlphaPredictiveFreeResultFn>(
      GetProcAddress(module, "alpha_predictive_free_similarities_result"));

  if (!create || !destroy || !compute || !free_result) {
    error =
        "alpha_input.dll does not export the required alpha_predictive_* APIs";
    FreeLibrary(module);
    return false;
  }

  g_alpha.module = module;
  g_alpha.create = create;
  g_alpha.destroy = destroy;
  g_alpha.compute_ordered = compute;
  g_alpha.apply_feedback = apply_feedback;
  g_alpha.update_preference = update_preference;
  g_alpha.free_result = free_result;
  g_alpha.library_path = library_path;
  return true;
}

bool EnsurePredictorUnlocked(const std::string& config_path_utf8,
                             const std::string& dll_path_utf8,
                             std::string& error) {
  const std::wstring library_path = ResolveLibraryPath(dll_path_utf8);
  if (!LoadAlphaLibraryUnlocked(library_path, error)) {
    return false;
  }

  if (g_alpha.predictor && g_alpha.config_path_utf8 == config_path_utf8) {
    return true;
  }

  ResetPredictorUnlocked();
  AlphaPredictiveHandle predictor = g_alpha.create(config_path_utf8.c_str());
  if (!predictor) {
    std::ostringstream ss;
    ss << "failed to initialize alpha predictor with config: "
       << config_path_utf8;
    error = ss.str();
    return false;
  }

  g_alpha.predictor = predictor;
  g_alpha.config_path_utf8 = config_path_utf8;
  return true;
}

std::vector<std::string> LuaCheckStringArray(lua_State* L, int index) {
  luaL_checktype(L, index, kLuaTypeTable);
  const size_t len = lua_rawlen(L, index);
  std::vector<std::string> values;
  values.reserve(len);
  for (size_t i = 1; i <= len; ++i) {
    lua_geti(L, index, static_cast<lua_Integer>(i));
    size_t item_len = 0;
    const char* item = luaL_checklstring(L, -1, &item_len);
    values.emplace_back(item ? std::string(item, item_len) : std::string());
    lua_pop(L, 1);
  }
  return values;
}

int LuaConfigure(lua_State* L) {
  luaL_checktype(L, 1, kLuaTypeTable);
  const std::string config_path = LuaGetOptionalStringField(L, 1, "config_path");
  const std::string dll_path = LuaGetOptionalStringField(L, 1, "dll_path");

  if (config_path.empty()) {
    return PushNilError(L, "config_path is required");
  }

  std::lock_guard<std::mutex> lock(g_alpha_mutex);
  std::string error;
  if (!EnsurePredictorUnlocked(config_path, dll_path, error)) {
    return PushNilError(L, error);
  }

  lua_pushboolean(L, 1);
  return 1;
}

int LuaReset(lua_State* L) {
  std::lock_guard<std::mutex> lock(g_alpha_mutex);
  ResetLibraryUnlocked();
  lua_pushboolean(L, 1);
  return 1;
}

int LuaIsReady(lua_State* L) {
  std::lock_guard<std::mutex> lock(g_alpha_mutex);
  lua_pushboolean(L, g_alpha.predictor != nullptr);
  return 1;
}

int LuaComputeSimilarities(lua_State* L) {
  const std::string input = LuaCheckString(L, 1);
  std::vector<std::string> candidates = LuaCheckStringArray(L, 2);

  if (candidates.empty()) {
    lua_newtable(L);
    return 1;
  }

  std::vector<const char*> candidate_ptrs;
  candidate_ptrs.reserve(candidates.size());
  for (const auto& candidate : candidates) {
    candidate_ptrs.push_back(candidate.c_str());
  }

  SimilarityResult* results = nullptr;
  int result_len = 0;
  {
    std::lock_guard<std::mutex> lock(g_alpha_mutex);
    if (!g_alpha.predictor || !g_alpha.compute_ordered || !g_alpha.free_result) {
      return PushNilError(L, "alpha_rerank_core is not configured");
    }
    result_len = g_alpha.compute_ordered(
        g_alpha.predictor, input.c_str(), candidate_ptrs.data(),
        static_cast<int>(candidate_ptrs.size()), &results);
  }

  if (result_len < 0 || !results) {
    return PushNilError(L, "alpha_input compute_similarities_ordered failed");
  }

  lua_createtable(L, result_len, 0);
  const int output_index = lua_gettop(L);
  for (int i = 0; i < result_len; ++i) {
    lua_pushnumber(L, static_cast<lua_Number>(results[i].score));
    lua_seti(L, output_index, static_cast<lua_Integer>(i + 1));
  }

  {
    std::lock_guard<std::mutex> lock(g_alpha_mutex);
    g_alpha.free_result(results, result_len);
  }
  return 1;
}

int LuaUpdateUserPreference(lua_State* L) {
  const std::string committed_text = LuaCheckString(L, 1);
  if (committed_text.empty()) {
    lua_pushboolean(L, 1);
    return 1;
  }

  std::lock_guard<std::mutex> lock(g_alpha_mutex);
  if (!g_alpha.predictor) {
    return PushNilError(L, "alpha_rerank_core is not configured");
  }
  if (!g_alpha.update_preference) {
    return PushNilError(
        L,
        "alpha_input.dll does not export alpha_predictive_update_user_preference");
  }

  const int status =
      g_alpha.update_preference(g_alpha.predictor, committed_text.c_str());
  if (status != 0) {
    return PushNilError(L, "alpha_input update_user_preference failed");
  }

  lua_pushboolean(L, 1);
  return 1;
}

int LuaApplyUserFeedback(lua_State* L) {
  const std::string committed_text = LuaCheckString(L, 1);
  std::vector<std::string> negative_candidates;
  if (lua_gettop(L) >= 2 && lua_type(L, 2) == kLuaTypeTable) {
    negative_candidates = LuaCheckStringArray(L, 2);
  }

  std::vector<const char*> negative_candidate_ptrs;
  negative_candidate_ptrs.reserve(negative_candidates.size());
  for (const auto& candidate : negative_candidates) {
    negative_candidate_ptrs.push_back(candidate.c_str());
  }

  std::lock_guard<std::mutex> lock(g_alpha_mutex);
  if (!g_alpha.predictor) {
    return PushNilError(L, "alpha_rerank_core is not configured");
  }

  if (g_alpha.apply_feedback) {
    const int status = g_alpha.apply_feedback(
        g_alpha.predictor, committed_text.c_str(),
        negative_candidate_ptrs.empty() ? nullptr : negative_candidate_ptrs.data(),
        static_cast<int>(negative_candidate_ptrs.size()));
    if (status != 0) {
      return PushNilError(L, "alpha_input apply_user_feedback failed");
    }
    lua_pushboolean(L, 1);
    return 1;
  }

  if (!g_alpha.update_preference) {
    return PushNilError(
        L,
        "alpha_input.dll does not export alpha_predictive_apply_user_feedback");
  }

  const int status =
      g_alpha.update_preference(g_alpha.predictor, committed_text.c_str());
  if (status != 0) {
    return PushNilError(L, "alpha_input update_user_preference failed");
  }

  lua_pushboolean(L, 1);
  return 1;
}

int LuaVersion(lua_State* L) {
  lua_pushstring(L, "alpha_rerank_core/1");
  return 1;
}

const luaL_Reg kModuleFunctions[] = {
    {"configure", LuaConfigure},
    {"reset", LuaReset},
    {"is_ready", LuaIsReady},
    {"compute_similarities", LuaComputeSimilarities},
    {"apply_user_feedback", LuaApplyUserFeedback},
    {"update_user_preference", LuaUpdateUserPreference},
    {"version", LuaVersion},
    {nullptr, nullptr},
};

}  // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
  if (reason == DLL_PROCESS_ATTACH) {
    g_self_module = module;
    g_alpha.module_dir = GetDllDirectory(module);
  }
  return TRUE;
}

extern "C" __declspec(dllexport) int luaopen_alpha_rerank_core(lua_State* L) {
  luaL_newlib(L, kModuleFunctions);
  return 1;
}

extern "C" __declspec(dllexport) int luaopen_wanxiang_alpha_rerank_core(
    lua_State* L) {
  return luaopen_alpha_rerank_core(L);
}
