local wanxiang = require("wanxiang/wanxiang")

local function try_require_alpha_core()
    local dll_path = wanxiang.get_filename_with_fallback("lua/wanxiang/alpha_rerank_core.dll")
    if dll_path and dll_path ~= "" and package and package.loadlib then
        local loader, err = package.loadlib(dll_path, "luaopen_alpha_rerank_core")
        if loader then
            local ok, mod = pcall(loader)
            if ok then
                return mod
            end
            if log and log.warning then
                log.warning("[alpha_rerank] failed to initialize alpha_rerank_core via loadlib: " .. tostring(mod))
            end
        elseif log and log.warning then
            log.warning("[alpha_rerank] package.loadlib failed: " .. tostring(err))
        end
    end

    local ok, mod = pcall(require, "wanxiang.alpha_rerank_core")
    if ok then return mod end
    ok, mod = pcall(require, "alpha_rerank_core")
    if ok then return mod end
    return nil
end

local alpha_core = try_require_alpha_core()

local M = {}

local DEFAULT_CONTEXT_MAX_CHARS = 96
local DEFAULT_MAX_CANDIDATES = 8
local DEFAULT_MAX_NEGATIVE_CANDIDATES = 3
local DEFAULT_RECENT_TAIL_CHARS = 24
local DEFAULT_ORDER_PRIOR_WEIGHT = 0.03
local DEFAULT_PRESERVE_FIRST_MIN_CHARS = 0
local DEFAULT_INPUT_COVERAGE_WEIGHT = 0.05
local DEFAULT_CONTEXT_SCAN_MULTIPLIER = 3
local DEFAULT_RECENT_CONTEXT_TARGET_SEGMENTS = 3
local DEFAULT_RECENT_CONTEXT_MAX_SEGMENTS = 4
local DEFAULT_ANCHOR_CONTEXT_TARGET_SEGMENTS = 4
local DEFAULT_ANCHOR_CONTEXT_MAX_SEGMENTS = 6
local DEFAULT_USER_RECORD_QUERY_WEIGHT = 0.20
local DEFAULT_RAW_CONTEXT_QUERY_WEIGHT = 0.60
local DEFAULT_RECENT_CLAUSE_QUERY_WEIGHT = 0.25
local DEFAULT_RECENT_TAIL_QUERY_WEIGHT = 0.20
local DEFAULT_ANCHOR_QUERY_WEIGHT = 0.35
local DEFAULT_RAW_CONTEXT_VIEW_WEIGHT = 0.28
local DEFAULT_SOFT_CLEAN_CONTEXT_VIEW_WEIGHT = 0.55
local DEFAULT_ANCHORED_CONTEXT_VIEW_WEIGHT = 0.32
local DEFAULT_DOMAIN_PRESERVED_CONTEXT_VIEW_WEIGHT = 0.35
local DEFAULT_LOG_PREVIEW_CHARS = 160
local DEFAULT_INPUT_COVERAGE_MIN_LETTERS = 8
local DEFAULT_MIN_CONTEXT_CONFIDENCE = 0.35
local DEFAULT_MEDIUM_CONTEXT_CONFIDENCE = 0.55
local DEFAULT_STRONG_CONTEXT_CONFIDENCE = 0.75
local DEFAULT_LOW_CONTEXT_TAKEOVER_EXTRA_MARGIN = 0.05
local DEFAULT_MEDIUM_CONTEXT_TAKEOVER_MARGIN_DISCOUNT = 0.015
local DEFAULT_STRONG_CONTEXT_TAKEOVER_MARGIN_DISCOUNT = 0.03
local CONTEXT_META_NOISE_SEGMENTS = {
    ["上下文"] = true,
    ["候选"] = true,
    ["候选池"] = true,
    ["排序"] = true,
    ["重排"] = true,
    ["日志"] = true,
    ["理论"] = true,
    ["样例"] = true,
    ["案例"] = true,
    ["测试"] = true,
    ["测试案例"] = true,
    ["词汇"] = true,
    ["跨度"] = true,
    ["输入法"] = true,
    ["语境"] = true,
    ["显示"] = true,
}
local CONTEXT_LEADING_FILLER_PATTERNS = {
    "^今天",
    "^明天",
    "^今晚",
    "^昨晚",
    "^上午",
    "^中午",
    "^下午",
    "^月底",
    "^这两天",
    "^这几天",
    "^最近",
    "^我想",
    "^想先",
    "^准备",
    "^打算",
    "^计划",
    "^先去",
    "^先把",
    "^先",
    "^再",
    "^然后",
    "^接着",
    "^继续",
    "^还得",
    "^还要",
    "^得先",
    "^得去",
    "^要先",
    "^要去",
    "^把",
    "^去",
    "^来",
    "^更新",
    "^补充",
    "^检查",
    "^统一",
    "^整理",
    "^处理",
    "^提交",
    "^拉",
    "^写",
    "^做",
    "^改",
    "^看",
}
local CONTEXT_TRAILING_FILLER_PATTERNS = {
    "一下$",
    "一下子$",
    "一遍$",
    "看看$",
}
local CONTEXT_TRAILING_PARTICLE_PATTERNS = {
    "了$",
    "吧$",
    "呢$",
    "呀$",
    "啊$",
    "吗$",
}
local CONTEXT_ANCHOR_TOKENS = {
    "去", "和", "把", "先", "再", "下午", "上午", "今晚", "明天", "下周", "月底",
    "酒店", "出差", "咳嗽", "发烧", "输入法", "优化", "延迟", "发布", "考试",
}
local DOMAIN_PRESERVED_TOKEN_PATTERNS = {
    "%u%u+",
    "%a+%.[%w_%-]+",
    "[%w_%-]+%.toml",
    "[%w_%-]+%.yaml",
    "[%w_%-]+%.json",
    "[%w_%-]+%.dll",
    "[%w_%-]+%.exe",
}
local BUSINESS_CONTEXT_TOKENS = {
    "公司", "财务", "报表", "业务", "营收", "收入", "成本", "利润", "预算", "审计", "会计",
    "经营", "市场", "销售", "合同", "客户", "项目", "管理", "风险", "融资", "投资",
}
local BUSINESS_CONTEXT_POSITIVE_CANDIDATES = {
    ["分析"] = 0.14,
    ["风险"] = 0.08,
    ["方向"] = 0.04,
    ["报告"] = 0.08,
    ["报表"] = 0.08,
    ["管理"] = 0.08,
    ["业务"] = 0.08,
    ["合同"] = 0.06,
    ["数据"] = 0.06,
    ["汇总"] = 0.05,
}
local BUSINESS_CONTEXT_NEGATIVE_CANDIDATES = {
    ["复习"] = -0.18,
    ["学习"] = -0.12,
    ["真题"] = -0.10,
    ["老师"] = -0.08,
    ["学校"] = -0.08,
}
local DEFAULT_QUALITY_PRIOR_WEIGHT = 0.12
local DEFAULT_PHRASE_TYPE_BONUS = 0.02
local DEFAULT_CONTRASTIVE_CORE_WEIGHT = 0.12
local DEFAULT_CONTRASTIVE_QUALITY_WEIGHT = 0.08
local DEFAULT_SHORTLIST_CONTRASTIVE_WEIGHT = 0.06
local DEFAULT_TOP1_TAKEOVER_MARGIN = 0.06
local DEFAULT_TOP1_TAKEOVER_DISTANCE_MARGIN = 0.015
local DEFAULT_TOP1_TAKEOVER_LONG_INPUT_MIN_LETTERS = 4
local DEFAULT_TOP1_TAKEOVER_LONG_INPUT_EXTRA_MARGIN = 0.22
local DEFAULT_MAX_CONTRASTIVE_CANDIDATE_CHARS = 8
local DEFAULT_SHORTLIST_MAX_CANDIDATE_CHARS = 4
local DEFAULT_GATE_SEMANTIC_WEIGHT = 0.34
local DEFAULT_GATE_PREFERENCE_WEIGHT = 0.08
local DEFAULT_GATE_ORDER_WEIGHT = 0.06
local DEFAULT_GATE_QUALITY_WEIGHT = 0.12
local DEFAULT_GATE_USER_FREQUENCY_WEIGHT = 0.16
local DEFAULT_GATE_COVERAGE_WEIGHT = 0.10
local DEFAULT_GATE_CONTINUATION_WEIGHT = 0.30
local DEFAULT_BASE_FREQUENCY_WEIGHT = 0.18
local DEFAULT_USER_FREQUENCY_SHORT_CANDIDATE_BOOST = 0.0
local DEFAULT_USER_FREQUENCY_FUNCTION_WORD_BOOST = 0.0
local DEFAULT_FUNCTION_WORD_CONTINUATION_BOOST = 0.0
local DEFAULT_FUNCTION_WORD_SEMANTIC_PENALTY = 0.12
local DEFAULT_SINGLE_CHAR_CONTINUATION_BOOST = 0.02
local DEFAULT_SHORT_CANDIDATE_CONTINUATION_BOOST = 0.01
local DEFAULT_LONG_CANDIDATE_SEMANTIC_BOOST = 0.08
local DEFAULT_LOW_CONTEXT_SEMANTIC_PENALTY = 0.10
local DEFAULT_STRONG_CONTEXT_CONTINUATION_BOOST = 0.05
local DEFAULT_CONTENT_WORD_SEMANTIC_BOOST = 0.06
local DEFAULT_MODAL_PARTICLE_PROMOTION_CAP = 0.02
local DEFAULT_FUNCTION_WORD_PROMOTION_CAP = 0.04
local DEFAULT_SINGLE_CHAR_PROMOTION_CAP = 0.04
local DEFAULT_SHORT_CANDIDATE_PROMOTION_CAP = 0.06
local DEFAULT_MODAL_PARTICLE_USER_FREQUENCY_SCALE = 0.0
local DEFAULT_FUNCTION_WORD_USER_FREQUENCY_SCALE = 0.10
local DEFAULT_SINGLE_CHAR_USER_FREQUENCY_SCALE = 0.10
local DEFAULT_SHORT_CANDIDATE_USER_FREQUENCY_SCALE = 0.25
local DEFAULT_USER_FREQUENCY_TIE_BREAK_GAP = 0.08
local DEFAULT_GENERIC_CONTINUATION_SCALE = 0.55
local DEFAULT_FUNCTION_WORD_CONTINUATION_SCALE = 0.20
local DEFAULT_MODAL_PARTICLE_CONTINUATION_SCALE = 0.10
local DEFAULT_SINGLE_CHAR_CONTINUATION_SCALE = 0.25
local DEFAULT_SHORT_CANDIDATE_CONTINUATION_SCALE = 0.40
local SCORE_EPSILON = 1e-9
local MODAL_PARTICLE_SET = {
    ["吧"] = true, ["呀"] = true, ["啊"] = true, ["呢"] = true, ["吗"] = true, ["嘛"] = true,
    ["啦"] = true, ["哇"] = true, ["呐"] = true, ["么"] = true, ["了"] = true,
}
local FUNCTION_WORD_SET = {
    ["的"] = true, ["了"] = true, ["呢"] = true, ["吗"] = true, ["吧"] = true, ["啊"] = true, ["呀"] = true,
    ["就"] = true, ["也"] = true, ["都"] = true, ["还"] = true, ["再"] = true, ["又"] = true, ["才"] = true,
    ["并"] = true, ["且"] = true, ["而"] = true, ["但"] = true, ["却"] = true, ["或"] = true, ["及"] = true,
    ["与"] = true, ["和"] = true, ["把"] = true, ["被"] = true, ["给"] = true, ["向"] = true, ["从"] = true,
    ["对"] = true, ["在"] = true, ["以"] = true, ["因"] = true, ["为"] = true, ["于"] = true, ["将"] = true,
    ["让"] = true, ["使"] = true, ["并且"] = true, ["而且"] = true, ["因为"] = true, ["所以"] = true,
    ["但是"] = true, ["如果"] = true, ["虽然"] = true, ["然后"] = true, ["于是"] = true, ["或者"] = true,
    ["以及"] = true, ["为了"] = true, ["的话"] = true, ["而已"] = true, ["就是"] = true, ["还是"] = true,
    ["已经"] = true, ["不能"] = true, ["可以"] = true, ["需要"] = true,
}

local function log_warn(message)
    if log and log.warning then
        log.warning(message)
    end
end

local function log_info(message)
    if log and log.info then
        log.info(message)
    elseif log and log.warning then
        log.warning(message)
    end
end

local function emit_log(env, message)
    if not env or not env.log_enabled then
        return nil
    end

    local prefix = string.format(
        "[RIME_LUA_ALPHA_RERANK][session=%s][trace_id=%s] ",
        tostring(env.log_session_id or "session"),
        tostring(env.current_trace_id or "init"))
    local line = prefix .. tostring(message or "")
    log_info(line)

    local log_path = tostring(env.log_file_path or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if env.log_phase == "init" and env.log_init_file_path and env.log_init_file_path ~= "" then
        log_path = env.log_init_file_path
    elseif env.log_phase == "eval" and env.log_eval_file_path and env.log_eval_file_path ~= "" then
        log_path = env.log_eval_file_path
    elseif env.log_rerank_file_path and env.log_rerank_file_path ~= "" then
        log_path = env.log_rerank_file_path
    end
    if log_path == "" or not io or type(io.open) ~= "function" then
        return nil
    end

    local file, err = io.open(log_path, "a")
    if not file then
        if not env.log_file_failed then
            env.log_file_failed = true
            log_warn("[alpha_rerank] failed to open log file: " .. tostring(err or log_path))
        end
        return nil
    end

    file:write(line .. "\n")
    file:close()
    return nil
end

local function trim_spaces(text)
    if text == nil then
        return ""
    end
    if type(text) ~= "string" then
        text = tostring(text)
    end
    if text == "" then return "" end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_absolute_path(path)
    if not path or path == "" then return false end
    if path:sub(1, 1) == "/" or path:sub(1, 1) == "\\" then
        return true
    end
    return path:match("^[a-zA-Z]:[\\/]")
end

local function resolve_path(path)
    path = trim_spaces(path or "")
    if path == "" then
        return ""
    end
    if is_absolute_path(path) then
        return path
    end
    local fallback = wanxiang.get_filename_with_fallback(path)
    return fallback or path
end

local function sibling_log_path(path, file_name)
    path = trim_spaces(path or "")
    if path == "" then return "" end
    local prefix = path:match("^(.*[\\/])[^\\/]*$")
    if not prefix or prefix == "" then return file_name end
    return prefix .. file_name
end

local function load_tags(config)
    local tags = {}
    local tag_list = config:get_list("alpha_rerank/tags")
    if tag_list and tag_list.size and tag_list.size > 0 then
        for i = 0, tag_list.size - 1 do
            local item = tag_list:get_value_at(i)
            local value = item and item.value or nil
            if value and value ~= "" then
                table.insert(tags, value)
            end
        end
    end
    if #tags == 0 then
        tags = { "abc" }
    end
    return tags
end

local function tags_match(seg, env)
    for _, tag in ipairs(env.tags) do
        if seg:has_tag(tag) then
            return true
        end
    end
    return false
end

local function utf8_len(text)
    if not text or text == "" then return 0 end
    if utf8 and utf8.len then
        local ok, len = pcall(utf8.len, text)
        if ok and len then return len end
    end
    local _, count = string.gsub(text, "[^\128-\193]", "")
    return count
end

local function utf8_to_chars(text)
    local chars = {}
    if not text or text == "" then
        return chars
    end
    for _, codepoint in utf8.codes(text) do
        chars[#chars + 1] = utf8.char(codepoint)
    end
    return chars
end

local function utf8_tail(text, keep)
    if not text or text == "" or keep <= 0 then
        return ""
    end
    local chars = utf8_to_chars(text)
    if #chars <= keep then
        return text
    end
    return table.concat(chars, "", #chars - keep + 1, #chars)
end

local function utf8_head(text, keep)
    if not text or text == "" or keep <= 0 then
        return ""
    end
    local chars = utf8_to_chars(text)
    if #chars <= keep then
        return text
    end
    return table.concat(chars, "", 1, keep)
end

local function clamp_tail_text(text, limit)
    if not text or text == "" or not limit or limit <= 0 then
        return text or ""
    end
    if utf8_len(text) <= limit then
        return text
    end
    return utf8_tail(text, limit)
end

local function clamp_head_tail_text(text, limit)
    if not text or text == "" or not limit or limit <= 0 then
        return text or ""
    end
    local length = utf8_len(text)
    if length <= limit then
        return text
    end
    if limit <= 1 then
        return utf8_head(text, limit)
    end
    local head_keep = math.max(1, math.floor((limit - 1) / 2))
    local tail_keep = math.max(1, limit - head_keep - 1)
    return utf8_head(text, head_keep) .. "…" .. utf8_tail(text, tail_keep)
end

local function join_text_array(values, separator)
    local parts = {}
    for i = 1, #values do
        local value = trim_spaces(values[i] or "")
        if value ~= "" then
            parts[#parts + 1] = value
        end
    end
    return table.concat(parts, separator or "")
end

local function try_get_candidate_field(candidate, field_name)
    local candidate_type = type(candidate)
    if candidate_type ~= "table" and candidate_type ~= "userdata" then
        return nil
    end

    local ok, value = pcall(function()
        return candidate[field_name]
    end)
    if ok then
        return value
    end
    return nil
end

local function next_trace_id(env)
    if not env then return "trace" end
    env.trace_sequence = (tonumber(env.trace_sequence or 0) or 0) + 1
    return string.format("%s-%05d", tostring(env.log_session_id or "trace"), env.trace_sequence)
end

local function get_candidate_text(candidate)
    local field_text = try_get_candidate_field(candidate, "text")
    if field_text ~= nil then
        return trim_spaces(field_text)
    end
    return trim_spaces(candidate or "")
end

local function get_candidate_quality(candidate)
    local field_quality = try_get_candidate_field(candidate, "quality")
    if field_quality == nil then
        return 0.0
    end
    return tonumber(field_quality or 0.0) or 0.0
end

local function get_candidate_type(candidate)
    local field_type = try_get_candidate_field(candidate, "type")
    if field_type == nil then
        return ""
    end
    return tostring(field_type or "")
end

local function candidate_is_phrase_like(candidate)
    local candidate_type = string.lower(get_candidate_type(candidate))
    if candidate_type == "" then
        return false
    end
    return string.find(candidate_type, "phrase", 1, true) ~= nil or
        string.find(candidate_type, "sentence", 1, true) ~= nil
end

local function format_text_array(values, limit)
    local preview = {}
    for i = 1, #values do
        preview[#preview + 1] = clamp_head_tail_text(trim_spaces(values[i] or ""), math.max(8, math.floor((limit or DEFAULT_LOG_PREVIEW_CHARS) / 3)))
    end
    return clamp_head_tail_text(table.concat(preview, " || "), limit or DEFAULT_LOG_PREVIEW_CHARS)
end

local function is_strong_sentence_boundary(ch)
    return ch == "。" or ch == "！" or ch == "？" or ch == "!" or
        ch == "?" or ch == "；" or ch == ";" or ch == "\n" or ch == "\r"
end

local function current_input_letter_count(current_input)
    local sanitized = tostring(current_input or ""):gsub("[^A-Za-z]", "")
    return #sanitized
end

local function estimate_expected_candidate_chars(current_input)
    local letters = current_input_letter_count(current_input)
    if letters < DEFAULT_INPUT_COVERAGE_MIN_LETTERS then
        return 0
    end
    return math.max(2, math.min(10, math.floor((letters + 3) / 4)))
end

local function compute_input_coverage_bonus(env, current_input, candidate_text, expected_chars)
    if not env or env.input_coverage_weight <= 0 then
        return 0.0, 0.0, expected_chars or 0
    end

    expected_chars = expected_chars or estimate_expected_candidate_chars(current_input)
    if expected_chars <= 0 then
        return 0.0, 0.0, expected_chars
    end

    local candidate_chars = utf8_len(candidate_text or "")
    if candidate_chars <= 0 then
        return 0.0, 0.0, expected_chars
    end

    local coverage_ratio = math.min(candidate_chars / expected_chars, 1.0)
    local bonus = env.input_coverage_weight * coverage_ratio
    return bonus, coverage_ratio, expected_chars
end

local function clamp01(value)
    value = tonumber(value or 0.0) or 0.0
    if value < 0.0 then return 0.0 end
    if value > 1.0 then return 1.0 end
    return value
end

local function clamp_signed_unit(value)
    value = tonumber(value or 0.0) or 0.0
    if value < -1.0 then return -1.0 end
    if value > 1.0 then return 1.0 end
    return value
end

local function candidate_is_function_word(info)
    if not info or not info.text or info.text == "" then
        return false
    end
    if FUNCTION_WORD_SET[info.text] then
        return true
    end

    local normalized_type = string.lower(tostring(info.type or ""))
    if normalized_type ~= "" and (
        string.find(normalized_type, "aux", 1, true) or
        string.find(normalized_type, "function", 1, true) or
        string.find(normalized_type, "particle", 1, true) or
        string.find(normalized_type, "connector", 1, true)
    ) then
        return true
    end

    return info.length > 0 and info.length <= 2 and (
        FUNCTION_WORD_SET[utf8_head(info.text, 1)] or
        FUNCTION_WORD_SET[utf8_tail(info.text, 1)])
end

local function candidate_is_modal_particle(info)
    if not info or not info.text or info.text == "" then
        return false
    end
    if MODAL_PARTICLE_SET[info.text] then
        return true
    end

    local normalized_type = string.lower(tostring(info.type or ""))
    if normalized_type ~= "" and string.find(normalized_type, "particle", 1, true) then
        return true
    end

    return info.length > 0 and info.length <= 2 and MODAL_PARTICLE_SET[utf8_tail(info.text, 1)]
end

local function build_candidate_role_profile(info)
    local is_modal_particle = candidate_is_modal_particle(info)
    local is_function_word = candidate_is_function_word(info)
    local is_single_char = info and info.length == 1 or false
    local is_short_candidate = info and info.length and info.length <= 2 or false
    local is_long_candidate = info and info.length and info.length >= 4 or false
    local is_phrase_like = candidate_is_phrase_like(info or {})
    local is_content_word = (not is_function_word) and (is_long_candidate or is_phrase_like or not is_short_candidate)
    return {
        is_function_word = is_function_word,
        is_modal_particle = is_modal_particle,
        is_single_char = is_single_char,
        is_short_candidate = is_short_candidate,
        is_long_candidate = is_long_candidate,
        is_phrase_like = is_phrase_like,
        is_content_word = is_content_word,
    }
end

local function candidate_role_label(profile)
    profile = profile or {}
    if profile.is_modal_particle then return "modal_particle" end
    if profile.is_function_word then return "function_word" end
    if profile.is_single_char then return "single_char" end
    if profile.is_short_candidate then return "short_candidate" end
    if profile.is_content_word then return "content_word" end
    return "other"
end

local function normalize_branch_score(value)
    if value == nil then
        return 0.0
    end
    return clamp_signed_unit(value)
end

local function normalize_nonnegative_score(value)
    if value == nil then
        return 0.0
    end
    return clamp01(tonumber(value) or 0.0)
end

local function compute_continuation_prior(env, info, context_snapshot, current_input, expected_candidate_chars)
    local profile = info.role_profile or build_candidate_role_profile(info)
    info.role_profile = profile

    local continuation = 0.0
    local semantic_adjustment = 0.0
    local context_confidence = tonumber(context_snapshot and context_snapshot.context_confidence or 0.0) or 0.0
    local input_letters = current_input_letter_count(current_input or "")

    if profile.is_function_word then
        semantic_adjustment = semantic_adjustment - env.function_word_semantic_penalty
    end
    if profile.is_modal_particle then
        semantic_adjustment = semantic_adjustment - (env.function_word_semantic_penalty * 0.5)
    elseif profile.is_single_char then
        continuation = continuation + env.single_char_continuation_boost
    elseif profile.is_short_candidate then
        continuation = continuation + env.short_candidate_continuation_boost
    end
    if profile.is_content_word then
        semantic_adjustment = semantic_adjustment + env.long_candidate_semantic_boost
    end
    if context_confidence < DEFAULT_MIN_CONTEXT_CONFIDENCE then
        semantic_adjustment = semantic_adjustment - env.low_context_semantic_penalty
    elseif context_confidence >= DEFAULT_STRONG_CONTEXT_CONFIDENCE then
        continuation = continuation + env.strong_context_continuation_boost
    end

    if expected_candidate_chars and expected_candidate_chars > 0 and info.length > 0 then
        if info.length <= expected_candidate_chars then
            continuation = continuation + math.min(info.length / expected_candidate_chars, 1.0) * 0.05
        else
            semantic_adjustment = semantic_adjustment + math.min((info.length - expected_candidate_chars) / 4.0, 1.0) * 0.04
        end
    end

    if input_letters <= 3 and profile.is_function_word then
        continuation = continuation * 0.5
    elseif input_letters >= 6 and profile.is_long_candidate then
        semantic_adjustment = semantic_adjustment + 0.03
    end

    if profile.is_modal_particle then
        continuation = continuation * env.modal_particle_continuation_scale
    elseif profile.is_function_word then
        continuation = continuation * env.function_word_continuation_scale
    elseif profile.is_single_char then
        continuation = continuation * env.single_char_continuation_scale
    elseif profile.is_short_candidate then
        continuation = continuation * env.short_candidate_continuation_scale
    else
        continuation = continuation * env.generic_continuation_scale
    end

    return clamp_signed_unit(continuation), clamp_signed_unit(semantic_adjustment)
end

local function build_breakdown_scores(env, query_variants, candidates, log_scope)
    if not env or not env.core or #query_variants == 0 or #candidates == 0 then
        return nil, 0
    end

    local scores = nil
    local successful_variants = 0
    for i = 1, #query_variants do
        local variant = query_variants[i]
        local variant_scores = nil
        local err = nil
        if type(env.core.compute_score_breakdowns) == "function" then
            variant_scores, err = env.core.compute_score_breakdowns(variant.text, candidates)
        else
            local fallback_scores
            fallback_scores, err = env.core.compute_similarities(variant.text, candidates)
            if fallback_scores then
                variant_scores = {}
                for j = 1, #fallback_scores do
                    variant_scores[j] = {
                        semantic_score = tonumber(fallback_scores[j]) or 0.0,
                        preference_score = 0.0,
                        final_score = tonumber(fallback_scores[j]) or 0.0,
                        dynamic_preference_factor = 0.0,
                    }
                end
            end
        end

        if variant_scores then
            successful_variants = successful_variants + 1
            if not scores then
                scores = {}
                for j = 1, #variant_scores do
                    local row = variant_scores[j] or {}
                    scores[j] = {
                        semantic_score = (tonumber(row.semantic_score) or 0.0) * variant.weight,
                        preference_score = (tonumber(row.preference_score) or 0.0) * variant.weight,
                        user_frequency_score = (tonumber(row.user_frequency_score) or 0.0) * variant.weight,
                        final_score = (tonumber(row.final_score) or 0.0) * variant.weight,
                        dynamic_preference_factor = (tonumber(row.dynamic_preference_factor) or 0.0) * variant.weight,
                    }
                end
            else
                for j = 1, #variant_scores do
                    local row = variant_scores[j] or {}
                    local entry = scores[j] or {}
                    entry.semantic_score = (entry.semantic_score or 0.0) + (tonumber(row.semantic_score) or 0.0) * variant.weight
                    entry.preference_score = (entry.preference_score or 0.0) + (tonumber(row.preference_score) or 0.0) * variant.weight
                    entry.user_frequency_score = (entry.user_frequency_score or 0.0) + (tonumber(row.user_frequency_score) or 0.0) * variant.weight
                    entry.final_score = (entry.final_score or 0.0) + (tonumber(row.final_score) or 0.0) * variant.weight
                    entry.dynamic_preference_factor = (entry.dynamic_preference_factor or 0.0) +
                        (tonumber(row.dynamic_preference_factor) or 0.0) * variant.weight
                    scores[j] = entry
                end
            end
        elseif env.log_enabled then
            emit_log(env, string.format(
                "%s query variant skipped, label=%s, error=%s",
                tostring(log_scope or "breakdown"),
                tostring(variant.label or "query"),
                tostring(err or "unknown error")))
        end
    end

    return scores, successful_variants
end

local function get_commit_history_segments(env)
    local records = {}
    local context = env.engine.context
    local history = context and context.commit_history or nil
    if not history or history:empty() then
        return records
    end

    local raw_records = history:to_table()
    if type(raw_records) ~= "table" then
        return records
    end

    for _, record in ipairs(raw_records) do
        local text = record and record.text or ""
        text = trim_spaces(text)
        if text ~= "" and text:sub(1, 1) ~= "/" then
            records[#records + 1] = text
        end
    end
    return records
end

local function get_commit_history_deduped_segments(env)
    local records = get_commit_history_segments(env)
    local segments = {}
    for _, text in ipairs(records) do
        if #segments == 0 or segments[#segments] ~= text then
            segments[#segments + 1] = text
        end
    end
    return segments
end

local function is_soft_clause_boundary(ch)
    return ch == "，" or ch == "," or ch == "、" or ch == "：" or ch == ":"
end

local function is_boundary_only_segment(text)
    text = trim_spaces(text or "")
    if text == "" then
        return false
    end
    local chars = utf8_to_chars(text)
    if #chars == 0 then
        return false
    end
    for i = 1, #chars do
        local ch = chars[i]
        if not is_strong_sentence_boundary(ch) and not is_soft_clause_boundary(ch) then
            return false
        end
    end
    return true
end

local function is_context_wrapper_noise_char(ch)
    return ch == "（" or ch == "）" or ch == "(" or ch == ")" or
        ch == "【" or ch == "】" or ch == "[" or ch == "]" or
        ch == "「" or ch == "」" or ch == "『" or ch == "』" or
        ch == "《" or ch == "》" or ch == "“" or ch == "”" or
        ch == "\"" or ch == "'" or ch == "…" or ch == "—" or ch == "-"
end

local function strip_context_wrapper_noise(text)
    text = trim_spaces(text or "")
    if text == "" then
        return ""
    end

    local chars = utf8_to_chars(text)
    local start_index = 1
    local end_index = #chars
    while start_index <= end_index and is_context_wrapper_noise_char(chars[start_index]) do
        start_index = start_index + 1
    end
    while end_index >= start_index and is_context_wrapper_noise_char(chars[end_index]) do
        end_index = end_index - 1
    end
    if end_index < start_index then
        return ""
    end
    return trim_spaces(table.concat(chars, "", start_index, end_index))
end

local function normalize_context_segment(text)
    text = trim_spaces(text or "")
    if text == "" then
        return ""
    end
    if is_boundary_only_segment(text) then
        local chars = utf8_to_chars(text)
        return chars[#chars] or ""
    end
    return strip_context_wrapper_noise(text)
end

local function is_low_information_context_segment(text)
    text = trim_spaces(text or "")
    if text == "" then
        return true
    end
    if CONTEXT_META_NOISE_SEGMENTS[text] then
        return true
    end
    local length = utf8_len(text)
    if length <= 1 then
        return true
    end
    if length <= 2 and text:match("^[A-Za-z]+$") then
        return true
    end
    return false
end

local function strip_context_clause_patterns(text, patterns)
    text = trim_spaces(text or "")
    if text == "" or type(patterns) ~= "table" then
        return text
    end

    local changed = true
    while changed and text ~= "" do
        changed = false
        for i = 1, #patterns do
            local updated, replacements = text:gsub(patterns[i], "", 1)
            if replacements and replacements > 0 then
                text = trim_spaces(updated)
                changed = true
            end
        end
    end
    return text
end

local function extract_meaningful_context_text(text)
    text = trim_spaces(text or "")
    if text == "" then
        return ""
    end

    local normalized = strip_context_wrapper_noise(text)
    normalized = trim_spaces(normalized:gsub("[%s　]", ""))
    normalized = strip_context_clause_patterns(normalized, CONTEXT_LEADING_FILLER_PATTERNS)
    normalized = strip_context_clause_patterns(normalized, CONTEXT_TRAILING_FILLER_PATTERNS)
    normalized = strip_context_clause_patterns(normalized, CONTEXT_TRAILING_PARTICLE_PATTERNS)
    normalized = normalized:gsub("[，,、：:；;。！？!?]", "")
    return trim_spaces(normalized)
end

local function is_low_information_context_clause(text)
    text = trim_spaces(text or "")
    if text == "" then
        return true
    end
    if is_low_information_context_segment(text) then
        return true
    end

    local original_len = utf8_len(text)
    local meaningful = extract_meaningful_context_text(text)
    local meaningful_len = utf8_len(meaningful)
    if meaningful_len <= 0 then
        return true
    end
    if meaningful_len <= 2 and meaningful:match("^[A-Za-z]+$") then
        return true
    end
    if original_len <= 6 and meaningful_len <= 2 then
        return true
    end
    if original_len <= 8 and meaningful_len <= 1 then
        return true
    end
    return false
end

local function filter_context_segments(segments)
    local filtered = {}
    for i = 1, #segments do
        local normalized = normalize_context_segment(segments[i] or "")
        if normalized ~= "" then
            if is_boundary_only_segment(normalized) then
                if #filtered > 0 and not is_boundary_only_segment(filtered[#filtered]) then
                    filtered[#filtered + 1] = normalized
                end
            elseif not is_low_information_context_segment(normalized) then
                if #filtered == 0 or filtered[#filtered] ~= normalized then
                    filtered[#filtered + 1] = normalized
                end
            end
        end
    end

    while #filtered > 0 and is_boundary_only_segment(filtered[1]) do
        table.remove(filtered, 1)
    end
    while #filtered > 0 and is_boundary_only_segment(filtered[#filtered]) do
        table.remove(filtered, #filtered)
    end
    return filtered
end

local function split_text_into_clauses(text, include_soft_boundary)
    local clauses = {}
    text = trim_spaces(text or "")
    if text == "" then
        return clauses
    end

    local chars = utf8_to_chars(text)
    local start_index = 1
    for i = 1, #chars do
        local ch = chars[i]
        if is_strong_sentence_boundary(ch) or (include_soft_boundary and is_soft_clause_boundary(ch)) then
            local clause = trim_spaces(table.concat(chars, "", start_index, i - 1))
            if clause ~= "" then
                clauses[#clauses + 1] = clause
            end
            start_index = i + 1
        end
    end

    local tail_clause = trim_spaces(table.concat(chars, "", start_index, #chars))
    if tail_clause ~= "" then
        clauses[#clauses + 1] = tail_clause
    end
    return clauses
end

local function select_recent_scan_segments(segments, char_limit)
    local reversed_segments = {}
    local accumulated = 0
    for i = #segments, 1, -1 do
        local segment = trim_spaces(segments[i] or "")
        if segment ~= "" then
            reversed_segments[#reversed_segments + 1] = segment
            accumulated = accumulated + utf8_len(segment)
            if accumulated >= char_limit then
                break
            end
        end
    end

    local selected = {}
    for i = #reversed_segments, 1, -1 do
        selected[#selected + 1] = reversed_segments[i]
    end
    return selected, join_text_array(selected, "")
end

local function take_segment_window(segments, end_index, options)
    local text_parts = {}
    local start_index = end_index + 1
    local char_count = 0
    local used_segments = 0
    local min_chars = options and options.min_chars or 0
    local target_segments = options and options.target_segments or 0
    local max_segments = options and options.max_segments or target_segments
    local max_chars = options and options.max_chars or 0

    for i = end_index, 1, -1 do
        local segment = trim_spaces(segments[i] or "")
        if segment ~= "" then
            if max_segments > 0 and used_segments >= max_segments then
                break
            end

            local segment_len = utf8_len(segment)
            if max_chars > 0 and used_segments > 0 and char_count >= min_chars and (char_count + segment_len) > max_chars then
                break
            end

            table.insert(text_parts, 1, segment)
            start_index = i
            char_count = char_count + segment_len
            used_segments = used_segments + 1

            local reached_target_segments = target_segments > 0 and used_segments >= target_segments
            local reached_target_chars = max_chars > 0 and char_count >= max_chars
            if (reached_target_segments or reached_target_chars) and char_count >= min_chars then
                break
            end
        end
    end

    return join_text_array(text_parts, ""), start_index, used_segments, char_count
end

local function compose_clean_context(anchor_clause, recent_clause, merged_tail)
    anchor_clause = trim_spaces(anchor_clause or "")
    recent_clause = trim_spaces(recent_clause or "")
    merged_tail = trim_spaces(merged_tail or "")

    if anchor_clause ~= "" and recent_clause ~= "" then
        if string.find(recent_clause, anchor_clause, 1, true) then
            return recent_clause
        end
        if string.find(anchor_clause, recent_clause, 1, true) then
            return anchor_clause
        end

        local anchor_chars = utf8_to_chars(anchor_clause)
        local last_char = anchor_chars[#anchor_chars] or ""
        local joiner = (is_strong_sentence_boundary(last_char) or is_soft_clause_boundary(last_char)) and "" or "，"
        return trim_spaces(anchor_clause .. joiner .. recent_clause)
    end

    if recent_clause ~= "" then
        return recent_clause
    end
    if merged_tail ~= "" then
        return merged_tail
    end
    return anchor_clause
end

local function collect_domain_preserved_tokens(text)
    local tokens = {}
    local seen = {}
    text = tostring(text or "")
    for _, pattern in ipairs(DOMAIN_PRESERVED_TOKEN_PATTERNS) do
        for token in string.gmatch(text, pattern) do
            token = trim_spaces(token or "")
            if token ~= "" and not seen[token] then
                tokens[#tokens + 1] = token
                seen[token] = true
            end
        end
    end
    return tokens
end

local function build_anchored_context(snapshot)
    snapshot = snapshot or {}
    local parts = {}
    local seen = {}
    local function add_text(text)
        text = trim_spaces(text or "")
        if text ~= "" and not seen[text] then
            parts[#parts + 1] = text
            seen[text] = true
        end
    end

    add_text(snapshot.anchor_clause)
    add_text(snapshot.recent_clause)
    add_text(snapshot.recent_tail)

    local source = trim_spaces(snapshot.scan_text or snapshot.merged_tail or "")
    for _, token in ipairs(CONTEXT_ANCHOR_TOKENS) do
        if string.find(source, token, 1, true) then
            add_text(token)
        end
    end

    return clamp_tail_text(join_text_array(parts, "，"), DEFAULT_CONTEXT_MAX_CHARS)
end

local function build_domain_preserved_context(snapshot)
    snapshot = snapshot or {}
    local source = trim_spaces(snapshot.scan_text or snapshot.merged_tail or "")
    local clean_context = trim_spaces(snapshot.clean_context or "")
    local anchored_context = trim_spaces(snapshot.anchored_context or "")
    local parts = {}
    local seen = {}
    local function add_text(text)
        text = trim_spaces(text or "")
        if text ~= "" and not seen[text] then
            parts[#parts + 1] = text
            seen[text] = true
        end
    end

    add_text(clean_context ~= "" and clean_context or source)
    for _, token in ipairs(collect_domain_preserved_tokens(source)) do
        add_text(token)
    end
    if anchored_context ~= "" then
        add_text(anchored_context)
    end

    return clamp_tail_text(join_text_array(parts, "，"), DEFAULT_CONTEXT_MAX_CHARS)
end

local function compute_context_confidence(snapshot)
    snapshot = snapshot or {}

    local confidence = 0.0
    if snapshot.anchor_informative then
        confidence = confidence + 0.45
    end
    if snapshot.recent_informative then
        confidence = confidence + 0.35
    end
    if snapshot.recent_tail_informative then
        confidence = confidence + 0.10
    end

    local effective_context = trim_spaces(snapshot.clean_context or "")
    local effective_chars = utf8_len(effective_context)
    if effective_chars >= 12 then
        confidence = confidence + 0.20
    elseif effective_chars >= 8 then
        confidence = confidence + 0.15
    elseif effective_chars >= 4 then
        confidence = confidence + 0.08
    end

    if snapshot.anchor_informative and snapshot.recent_informative then
        confidence = confidence + 0.10
    end
    return math.min(confidence, 1.0)
end

local function build_context_snapshot(env)
    local limit = env.context_max_chars > 0 and env.context_max_chars or DEFAULT_CONTEXT_MAX_CHARS
    local recent_tail_chars = env.recent_tail_chars > 0 and env.recent_tail_chars or DEFAULT_RECENT_TAIL_CHARS
    local raw_records = get_commit_history_segments(env)
    local deduped_segments = {}
    for _, text in ipairs(raw_records) do
        if #deduped_segments == 0 or deduped_segments[#deduped_segments] ~= text then
            deduped_segments[#deduped_segments + 1] = text
        end
    end

    local snapshot = {
        raw_records = raw_records,
        deduped_segments = deduped_segments,
        filtered_segments = {},
        scan_segments = {},
        scan_text = "",
        merged_tail = "",
        clauses = {},
        anchor_clause = "",
        recent_clause = "",
        recent_tail = "",
        clean_context = "",
        raw_context = "",
        soft_clean_context = "",
        anchored_context = "",
        domain_preserved_context = "",
        anchor_informative = false,
        recent_informative = false,
        recent_tail_informative = false,
        merged_tail_informative = false,
        context_confidence = 0.0,
    }

    if #deduped_segments == 0 then
        return snapshot
    end

    local filtered_segments = filter_context_segments(deduped_segments)
    snapshot.filtered_segments = filtered_segments
    if #filtered_segments == 0 then
        return snapshot
    end

    local scan_limit = math.max(
        limit * DEFAULT_CONTEXT_SCAN_MULTIPLIER,
        recent_tail_chars * 8,
        DEFAULT_CONTEXT_MAX_CHARS)
    local scan_segments, scan_text = select_recent_scan_segments(filtered_segments, scan_limit)
    snapshot.scan_segments = scan_segments
    snapshot.scan_text = scan_text
    snapshot.merged_tail = clamp_tail_text(scan_text, limit)

    if env.prefer_sentence_boundary then
        snapshot.clauses = split_text_into_clauses(scan_text, true)
        if #snapshot.clauses >= 1 then
            snapshot.recent_clause = snapshot.clauses[#snapshot.clauses]
        end
        if #snapshot.clauses >= 2 then
            snapshot.anchor_clause = snapshot.clauses[#snapshot.clauses - 1]
        end
    end

    local recent_window, recent_start = take_segment_window(scan_segments, #scan_segments, {
        min_chars = 4,
        target_segments = DEFAULT_RECENT_CONTEXT_TARGET_SEGMENTS,
        max_segments = DEFAULT_RECENT_CONTEXT_MAX_SEGMENTS,
        max_chars = math.max(10, recent_tail_chars),
    })
    if snapshot.recent_clause == "" or utf8_len(snapshot.recent_clause) < 4 then
        snapshot.recent_clause = recent_window
    end

    if recent_start > 1 then
        local anchor_window = take_segment_window(scan_segments, recent_start - 1, {
            min_chars = 4,
            target_segments = DEFAULT_ANCHOR_CONTEXT_TARGET_SEGMENTS,
            max_segments = DEFAULT_ANCHOR_CONTEXT_MAX_SEGMENTS,
            max_chars = math.max(12, recent_tail_chars + 8),
        })
        if snapshot.anchor_clause == "" or utf8_len(snapshot.anchor_clause) < 4 then
            snapshot.anchor_clause = anchor_window
        end
    end

    snapshot.recent_tail = utf8_tail(snapshot.scan_text ~= "" and snapshot.scan_text or snapshot.merged_tail, recent_tail_chars)
    if snapshot.anchor_clause == snapshot.recent_clause then
        snapshot.anchor_clause = ""
    end
    snapshot.anchor_informative = snapshot.anchor_clause ~= "" and
        not is_low_information_context_clause(snapshot.anchor_clause)
    snapshot.recent_informative = snapshot.recent_clause ~= "" and
        not is_low_information_context_clause(snapshot.recent_clause)
    snapshot.recent_tail_informative = snapshot.recent_tail ~= "" and
        not is_low_information_context_clause(snapshot.recent_tail)
    snapshot.merged_tail_informative = snapshot.merged_tail ~= "" and
        not is_low_information_context_clause(snapshot.merged_tail)

    local effective_anchor = snapshot.anchor_informative and snapshot.anchor_clause or ""
    local effective_recent = snapshot.recent_informative and snapshot.recent_clause or ""
    local effective_tail = ""
    if effective_anchor == "" and effective_recent == "" then
        if snapshot.recent_tail_informative then
            effective_tail = snapshot.recent_tail
        elseif snapshot.merged_tail_informative then
            effective_tail = snapshot.merged_tail
        end
    end

    snapshot.clean_context = compose_clean_context(effective_anchor, effective_recent, effective_tail)
    snapshot.raw_context = clamp_tail_text(snapshot.scan_text ~= "" and snapshot.scan_text or snapshot.merged_tail, limit)
    snapshot.soft_clean_context = snapshot.clean_context
    snapshot.anchored_context = build_anchored_context(snapshot)
    snapshot.domain_preserved_context = build_domain_preserved_context(snapshot)
    snapshot.context_confidence = compute_context_confidence(snapshot)
    return snapshot
end

local function emit_context_snapshot_logs(env, stage, snapshot)
    if not env.log_enabled then
        return
    end

    local signature = table.concat({
        tostring(stage or "context"),
        snapshot.clean_context or "",
        "\30",
        snapshot.anchored_context or "",
        "\30",
        snapshot.domain_preserved_context or "",
        "\30",
        snapshot.recent_clause or "",
        "\30",
        snapshot.anchor_clause or "",
        "\30",
        table.concat(snapshot.scan_segments or {}, "\31"),
    })
    if env.last_context_log_signature == signature then
        return
    end
    env.last_context_log_signature = signature

    emit_log(env, string.format("%s raw_commit_history=%s", tostring(stage or "context"), format_text_array(snapshot.raw_records or {})))
    emit_log(env, string.format("%s deduped_segments=%s", tostring(stage or "context"), format_text_array(snapshot.deduped_segments or {})))
    emit_log(env, string.format("%s filtered_segments=%s", tostring(stage or "context"), format_text_array(snapshot.filtered_segments or {})))
    emit_log(env, string.format("%s scan_segments=%s", tostring(stage or "context"), format_text_array(snapshot.scan_segments or {})))
    emit_log(env, string.format("%s clauses=%s", tostring(stage or "context"), format_text_array(snapshot.clauses or {})))
    emit_log(env, string.format("%s anchor_clause=%s", tostring(stage or "context"), clamp_head_tail_text(snapshot.anchor_clause or "", DEFAULT_LOG_PREVIEW_CHARS)))
    emit_log(env, string.format("%s recent_clause=%s", tostring(stage or "context"), clamp_head_tail_text(snapshot.recent_clause or "", DEFAULT_LOG_PREVIEW_CHARS)))
    emit_log(env, string.format("%s recent_tail=%s", tostring(stage or "context"), clamp_head_tail_text(snapshot.recent_tail or "", DEFAULT_LOG_PREVIEW_CHARS)))
    emit_log(env, string.format("%s clean_context=%s", tostring(stage or "context"), clamp_head_tail_text(snapshot.clean_context or "", DEFAULT_LOG_PREVIEW_CHARS)))
    emit_log(env, string.format("%s context_views raw=%s | soft=%s | anchored=%s | domain=%s",
        tostring(stage or "context"),
        clamp_head_tail_text(snapshot.raw_context or "", DEFAULT_LOG_PREVIEW_CHARS),
        clamp_head_tail_text(snapshot.soft_clean_context or "", DEFAULT_LOG_PREVIEW_CHARS),
        clamp_head_tail_text(snapshot.anchored_context or "", DEFAULT_LOG_PREVIEW_CHARS),
        clamp_head_tail_text(snapshot.domain_preserved_context or "", DEFAULT_LOG_PREVIEW_CHARS)))
    emit_log(env,
        string.format(
            "%s context_flags=anchor:%s,recent:%s,tail:%s,merged:%s confidence=%.2f",
            tostring(stage or "context"),
            tostring(snapshot.anchor_informative),
            tostring(snapshot.recent_informative),
            tostring(snapshot.recent_tail_informative),
            tostring(snapshot.merged_tail_informative),
            tonumber(snapshot.context_confidence or 0.0) or 0.0))
end

local function find_sequence_overlap(previous_records, current_records)
    local max_overlap = math.min(#previous_records, #current_records)
    for overlap = max_overlap, 0, -1 do
        local matched = true
        for i = 1, overlap do
            if previous_records[#previous_records - overlap + i] ~= current_records[i] then
                matched = false
                break
            end
        end
        if matched then
            return overlap
        end
    end
    return 0
end

local clear_feedback_session
local build_feedback_for_commit
local apply_user_feedback
local join_candidate_preview

local function sync_user_preference(env)
    if not env.backend_ready or not env.core or env.preference_sync_disabled then
        return
    end
    if type(env.core.apply_user_feedback) ~= "function" and
        type(env.core.update_user_preference) ~= "function" then
        env.preference_sync_disabled = true
        return
    end

    local records = get_commit_history_segments(env)
    if not env.preference_history_snapshot then
        env.preference_history_snapshot = records
        return
    end

    local overlap = find_sequence_overlap(env.preference_history_snapshot, records)
    local consumed_feedback_session = false
    for i = overlap + 1, #records do
        local text = records[i]
        if text and text ~= "" then
            local feedback = {
                positive = text,
                negatives = {},
                matched = false,
            }
            if not consumed_feedback_session then
                local derived_feedback = build_feedback_for_commit(env, text)
                if derived_feedback then
                    feedback = derived_feedback
                end
                consumed_feedback_session = true
                clear_feedback_session(env)
            end

            local ok, err = apply_user_feedback(env, feedback.positive, feedback.negatives)
            if not ok then
                env.preference_sync_disabled = true
                log_warn("[alpha_rerank] apply_user_feedback failed: " .. tostring(err or "unknown error"))
                break
            end
            if env.log_enabled then
                emit_log(env,
                    string.format(
                        "user feedback updated: chosen=%s, matched=%s, negatives=%s",
                        tostring(feedback.positive),
                        tostring(feedback.matched),
                        join_candidate_preview(feedback.negatives)))
            end
        end
    end

    env.preference_history_snapshot = records
end

local function build_rerank_context(snapshot, recent_tail_chars, context_max_chars)
    snapshot = snapshot or {}
    local limit = context_max_chars > 0 and context_max_chars or DEFAULT_CONTEXT_MAX_CHARS
    local clean_context = trim_spaces(snapshot.clean_context or "")
    if clean_context == "" and snapshot.merged_tail_informative then
        clean_context = trim_spaces(snapshot.merged_tail or "")
    end
    if clean_context == "" then
        return ""
    end

    return clamp_head_tail_text(clean_context, limit)
end

local function append_query_variant(variants, seen, label, text, weight, limit)
    text = trim_spaces(text or "")
    if text == "" or not weight or weight <= 0 then
        return
    end

    text = clamp_head_tail_text(text, limit)
    if text == "" then
        return
    end

    local existing = seen[text]
    if existing then
        existing.weight = math.max(existing.weight or 0, weight)
        return
    end

    local variant = {
        label = label or "query",
        text = text,
        weight = weight,
    }
    variants[#variants + 1] = variant
    seen[text] = variant
end

local function normalize_query_variant_weights(variants)
    local total_weight = 0.0
    for i = 1, #variants do
        total_weight = total_weight + math.max(tonumber(variants[i].weight) or 0.0, 0.0)
    end

    if total_weight <= 0.0 then
        return variants
    end

    for i = 1, #variants do
        variants[i].weight = (tonumber(variants[i].weight) or 0.0) / total_weight
    end
    return variants
end

local function build_query_variants(snapshot, recent_tail_chars, context_max_chars)
    snapshot = snapshot or {}
    local limit = context_max_chars > 0 and context_max_chars or DEFAULT_CONTEXT_MAX_CHARS
    local variants = {}
    local seen = {}

    local clean_context = build_rerank_context(snapshot, recent_tail_chars, context_max_chars)
    local raw_context = trim_spaces(snapshot.raw_context or "")
    local soft_clean_context = trim_spaces(snapshot.soft_clean_context or clean_context)
    local anchored_context = trim_spaces(snapshot.anchored_context or "")
    local domain_preserved_context = trim_spaces(snapshot.domain_preserved_context or "")
    if raw_context ~= "" then
        append_query_variant(variants, seen, "raw_context", raw_context, DEFAULT_RAW_CONTEXT_VIEW_WEIGHT, limit)
    end
    append_query_variant(
        variants,
        seen,
        "user_record_context",
        soft_clean_context ~= "" and ("用户输入记录：" .. soft_clean_context) or "",
        DEFAULT_USER_RECORD_QUERY_WEIGHT,
        limit)
    append_query_variant(
        variants,
        seen,
        "soft_clean_context",
        soft_clean_context,
        DEFAULT_SOFT_CLEAN_CONTEXT_VIEW_WEIGHT,
        limit)
    if anchored_context ~= "" and anchored_context ~= soft_clean_context then
        append_query_variant(variants, seen, "anchored_context", anchored_context, DEFAULT_ANCHORED_CONTEXT_VIEW_WEIGHT, limit)
    end
    if domain_preserved_context ~= "" and domain_preserved_context ~= soft_clean_context and domain_preserved_context ~= anchored_context then
        append_query_variant(variants, seen, "domain_preserved_context", domain_preserved_context, DEFAULT_DOMAIN_PRESERVED_CONTEXT_VIEW_WEIGHT, limit)
    end

    local recent_clause = trim_spaces(snapshot.recent_clause or "")
    if snapshot.recent_informative and recent_clause ~= "" and recent_clause ~= clean_context then
        append_query_variant(
            variants,
            seen,
            "recent_clause_context",
            recent_clause,
            DEFAULT_RECENT_CLAUSE_QUERY_WEIGHT,
            limit)
    end

    local recent_tail = trim_spaces(snapshot.recent_tail or "")
    if snapshot.recent_tail_informative and recent_tail ~= "" and recent_tail ~= clean_context then
        append_query_variant(
            variants,
            seen,
            "recent_tail_context",
            "最近输入片段：" .. recent_tail,
            DEFAULT_RECENT_TAIL_QUERY_WEIGHT,
            limit)
    end

    local anchor_clause = trim_spaces(snapshot.anchor_clause or "")
    if snapshot.anchor_informative and anchor_clause ~= "" and anchor_clause ~= clean_context and utf8_len(anchor_clause) >= 4 then
        append_query_variant(variants, seen, "anchor_clause", anchor_clause, DEFAULT_ANCHOR_QUERY_WEIGHT, limit)
    end

    return normalize_query_variant_weights(variants)
end

local function build_contrastive_query_variants(snapshot, recent_tail_chars, context_max_chars)
    snapshot = snapshot or {}
    local limit = context_max_chars > 0 and context_max_chars or DEFAULT_CONTEXT_MAX_CHARS
    local variants = {}
    local seen = {}

    local recent_clause = trim_spaces(snapshot.recent_clause or "")
    if snapshot.recent_informative then
        append_query_variant(variants, seen, "recent_clause", recent_clause, 1.0, limit)
    end

    local recent_tail = trim_spaces(snapshot.recent_tail or "")
    if snapshot.recent_tail_informative and recent_tail ~= "" and recent_tail ~= recent_clause then
        append_query_variant(variants, seen, "recent_tail", recent_tail, 0.75, limit)
    end

    local clean_context = build_rerank_context(snapshot, recent_tail_chars, context_max_chars)
    if clean_context ~= "" and clean_context ~= recent_clause and clean_context ~= recent_tail then
        append_query_variant(variants, seen, "clean_context", clean_context, 0.45, limit)
    end

    return variants
end

local function build_weighted_similarity_scores(env, query_variants, candidates, log_scope)
    if not env or not env.core or #query_variants == 0 or #candidates == 0 then
        return nil, 0
    end

    local scores = nil
    local successful_variants = 0
    for i = 1, #query_variants do
        local variant = query_variants[i]
        local variant_scores, err = env.core.compute_similarities(variant.text, candidates)
        if variant_scores then
            successful_variants = successful_variants + 1
            if not scores then
                scores = {}
                for j = 1, #variant_scores do
                    scores[j] = (tonumber(variant_scores[j]) or 0.0) * variant.weight
                end
            else
                for j = 1, #variant_scores do
                    scores[j] = (scores[j] or 0.0) + (tonumber(variant_scores[j]) or 0.0) * variant.weight
                end
            end
        elseif env.log_enabled then
            emit_log(env, string.format(
                "%s query variant skipped, label=%s, error=%s",
                tostring(log_scope or "semantic"),
                tostring(variant.label or "query"),
                tostring(err or "unknown error")))
        end
    end

    if scores then
        for i = 1, #candidates do
            scores[i] = tonumber(scores[i]) or 0.0
        end
    end
    return scores, successful_variants
end

local function utf8_common_prefix_len(left_chars, right_chars)
    local limit = math.min(#left_chars, #right_chars)
    local matched = 0
    while matched < limit and left_chars[matched + 1] == right_chars[matched + 1] do
        matched = matched + 1
    end
    return matched
end

local function utf8_common_suffix_len(left_chars, right_chars, prefix_limit)
    local left_start = (prefix_limit or 0) + 1
    local right_start = (prefix_limit or 0) + 1
    local left_remaining = #left_chars - left_start + 1
    local right_remaining = #right_chars - right_start + 1
    local limit = math.min(left_remaining, right_remaining)
    local matched = 0
    while matched < limit do
        local left_index = #left_chars - matched
        local right_index = #right_chars - matched
        if left_index < left_start or right_index < right_start then
            break
        end
        if left_chars[left_index] ~= right_chars[right_index] then
            break
        end
        matched = matched + 1
    end
    return matched
end

local function build_candidate_info(candidate, original_index)
    local text = get_candidate_text(candidate)
    if text == "" then
        return nil
    end

    local chars = utf8_to_chars(text)
    local info = {
        candidate = candidate,
        text = text,
        chars = chars,
        length = #chars,
        quality = get_candidate_quality(candidate),
        type = get_candidate_type(candidate),
        original_index = original_index or 0,
    }
    info.role_profile = build_candidate_role_profile(info)
    return info
end

local function build_candidate_infos(candidates)
    local infos = {}
    for i = 1, #candidates do
        local info = build_candidate_info(candidates[i], i)
        if info then
            infos[#infos + 1] = info
        end
    end
    return infos
end

local function extract_candidate_texts(candidate_infos)
    local texts = {}
    for i = 1, #candidate_infos do
        texts[i] = candidate_infos[i].text
    end
    return texts
end

local function format_candidate_quality_preview(candidate_infos)
    local preview = {}
    for i = 1, #candidate_infos do
        local info = candidate_infos[i] or {}
        preview[#preview + 1] = string.format(
            "%s(q=%.3f,t=%s,role=%s,len=%d)",
            tostring(info.text or ""),
            tonumber(info.quality or 0.0) or 0.0,
            tostring(info.type or ""),
            candidate_role_label(info.role_profile),
            tonumber(info.length or 0) or 0)
    end
    return clamp_head_tail_text(table.concat(preview, " | "), DEFAULT_LOG_PREVIEW_CHARS)
end

local function normalized_centered_values(values)
    local normalized = {}
    if #values == 0 then
        return normalized
    end

    local sum = 0.0
    for i = 1, #values do
        sum = sum + (tonumber(values[i]) or 0.0)
    end
    local mean = sum / #values

    local max_delta = 0.0
    for i = 1, #values do
        local delta = math.abs((tonumber(values[i]) or 0.0) - mean)
        if delta > max_delta then
            max_delta = delta
        end
    end

    if max_delta <= SCORE_EPSILON then
        for i = 1, #values do
            normalized[i] = 0.0
        end
        return normalized
    end

    for i = 1, #values do
        normalized[i] = ((tonumber(values[i]) or 0.0) - mean) / max_delta
    end
    return normalized
end

local function apply_centered_bonus(scores, values, indices, weight, bonuses)
    if not weight or weight <= 0 or #values == 0 then
        return
    end

    local normalized = normalized_centered_values(values)
    for i = 1, #indices do
        local candidate_index = indices[i]
        local bonus = (normalized[i] or 0.0) * weight
        scores[candidate_index] = (scores[candidate_index] or 0.0) + bonus
        bonuses[candidate_index] = (bonuses[candidate_index] or 0.0) + bonus
    end
end

local function candidate_infos_share_affix(lhs, rhs, max_candidate_chars)
    if not lhs or not rhs then
        return false
    end
    if lhs.length < 2 or rhs.length < 2 then
        return false
    end
    if lhs.length > max_candidate_chars or rhs.length > max_candidate_chars then
        return false
    end

    local prefix_len = utf8_common_prefix_len(lhs.chars, rhs.chars)
    local suffix_len = utf8_common_suffix_len(lhs.chars, rhs.chars, prefix_len)
    return (prefix_len > 0 or suffix_len > 0) and (prefix_len + suffix_len) < math.min(lhs.length, rhs.length)
end

local function make_affix_family_group(candidate_infos, indices, env)
    if #indices < 2 then
        return nil
    end

    local shared_prefix = nil
    for i = 1, #indices do
        local info = candidate_infos[indices[i]]
        if shared_prefix == nil then
            shared_prefix = info.length
        else
            shared_prefix = math.min(shared_prefix, utf8_common_prefix_len(candidate_infos[indices[1]].chars, info.chars))
        end
    end
    shared_prefix = shared_prefix or 0

    local shared_suffix = nil
    for i = 1, #indices do
        local info = candidate_infos[indices[i]]
        if shared_suffix == nil then
            shared_suffix = info.length - shared_prefix
        else
            shared_suffix = math.min(
                shared_suffix,
                utf8_common_suffix_len(candidate_infos[indices[1]].chars, info.chars, shared_prefix))
        end
    end
    shared_suffix = shared_suffix or 0

    local contrast_texts = {}
    local has_changed_core = false
    for i = 1, #indices do
        local info = candidate_infos[indices[i]]
        local keep_start = shared_prefix + 1
        local keep_end = info.length - shared_suffix
        if keep_end < keep_start then
            keep_start = math.min(info.length, shared_prefix + 1)
            keep_end = keep_start
        end
        local core = table.concat(info.chars, "", keep_start, keep_end)
        if core == "" then
            core = info.text
        end
        contrast_texts[i] = core
        if core ~= info.text then
            has_changed_core = true
        end
    end

    if not has_changed_core then
        return nil
    end

    return {
        kind = "affix",
        indices = indices,
        contrast_texts = contrast_texts,
        semantic_weight = (env and env.contrastive_core_weight) or DEFAULT_CONTRASTIVE_CORE_WEIGHT,
        quality_weight = (env and env.contrastive_quality_weight) or DEFAULT_CONTRASTIVE_QUALITY_WEIGHT,
        prefix_chars = shared_prefix,
        suffix_chars = shared_suffix,
    }
end

local function build_contrastive_groups(candidate_infos, env)
    local groups = {}
    local covered = {}
    local visited = {}
    local max_candidate_chars = (env and env.max_contrastive_candidate_chars) or DEFAULT_MAX_CONTRASTIVE_CANDIDATE_CHARS

    for i = 1, #candidate_infos do
        if not visited[i] then
            local queue = { i }
            local head = 1
            local component = {}
            visited[i] = true

            while head <= #queue do
                local current = queue[head]
                head = head + 1
                component[#component + 1] = current

                for j = 1, #candidate_infos do
                    if not visited[j] and candidate_infos_share_affix(candidate_infos[current], candidate_infos[j], max_candidate_chars) then
                        visited[j] = true
                        queue[#queue + 1] = j
                    end
                end
            end

            if #component >= 2 then
                local group = make_affix_family_group(candidate_infos, component, env)
                if group then
                    groups[#groups + 1] = group
                    for _, index in ipairs(component) do
                        covered[index] = true
                    end
                end
            end
        end
    end

    local shortlist_groups = {}
    local shortlist_limit = (env and env.shortlist_contrastive_max_chars) or DEFAULT_SHORTLIST_MAX_CANDIDATE_CHARS
    for i = 1, #candidate_infos do
        local info = candidate_infos[i]
        if info.length >= 2 and info.length <= shortlist_limit then
            shortlist_groups[info.length] = shortlist_groups[info.length] or {}
            shortlist_groups[info.length][#shortlist_groups[info.length] + 1] = i
        end
    end

    for _, indices in pairs(shortlist_groups) do
        if #indices >= 2 then
            local contrast_texts = {}
            for i = 1, #indices do
                contrast_texts[i] = candidate_infos[indices[i]].text
            end
            groups[#groups + 1] = {
                kind = "shortlist",
                indices = indices,
                contrast_texts = contrast_texts,
                semantic_weight = (env and env.shortlist_contrastive_weight) or DEFAULT_SHORTLIST_CONTRASTIVE_WEIGHT,
                quality_weight = (env and env.contrastive_quality_weight) or DEFAULT_CONTRASTIVE_QUALITY_WEIGHT,
                prefix_chars = 0,
                suffix_chars = 0,
            }
        end
    end

    return groups
end

local function apply_quality_prior(scores, candidate_infos, env, quality_bonuses)
    if not env or env.quality_prior_weight <= 0 or #candidate_infos == 0 then
        return
    end

    local quality_values = {}
    local indices = {}
    for i = 1, #candidate_infos do
        quality_values[i] = candidate_infos[i].quality or 0.0
        indices[i] = i
    end
    apply_centered_bonus(scores, quality_values, indices, env.quality_prior_weight, quality_bonuses)

    if env.phrase_type_bonus > 0 then
        for i = 1, #candidate_infos do
            if candidate_is_phrase_like(candidate_infos[i]) then
                scores[i] = (scores[i] or 0.0) + env.phrase_type_bonus
                quality_bonuses[i] = (quality_bonuses[i] or 0.0) + env.phrase_type_bonus
            end
        end
    end
end

local function apply_user_frequency_prior(scores, branch_scores, candidate_infos, env, user_frequency_bonuses)
    if not env or env.gate_user_frequency_weight <= 0 or #candidate_infos == 0 then
        return
    end

    local original_score = tonumber(scores[1] or 0.0) or 0.0
    local values = {}
    local indices = {}
    for i = 1, #candidate_infos do
        local info = candidate_infos[i] or {}
        local branch = branch_scores[i] or {}
        local profile = info.role_profile or build_candidate_role_profile(info)
        info.role_profile = profile

        local candidate_user_frequency = normalize_nonnegative_score(branch.user_frequency_raw or branch.user_frequency or 0.0)
        if profile.is_modal_particle then
            candidate_user_frequency = candidate_user_frequency * env.modal_particle_user_frequency_scale
        elseif profile.is_function_word then
            candidate_user_frequency = candidate_user_frequency * env.function_word_user_frequency_scale
        elseif profile.is_single_char then
            candidate_user_frequency = candidate_user_frequency * env.single_char_user_frequency_scale
        elseif profile.is_short_candidate then
            candidate_user_frequency = candidate_user_frequency * env.short_candidate_user_frequency_scale
        end

        local score_gap = math.abs((tonumber(scores[i] or 0.0) or 0.0) - original_score)
        if score_gap > env.user_frequency_tie_break_gap then
            candidate_user_frequency = 0.0
        end

        values[i] = candidate_user_frequency
        indices[i] = i
        branch.user_frequency = candidate_user_frequency
        branch_scores[i] = branch
    end

    apply_centered_bonus(scores, values, indices, env.gate_user_frequency_weight, user_frequency_bonuses)
end

local function context_matches_token_set(context_snapshot, token_set)
    if not context_snapshot or not token_set then
        return false
    end
    local context_text = table.concat({
        tostring(context_snapshot.raw_context or ""),
        tostring(context_snapshot.clean_context or ""),
        tostring(context_snapshot.soft_clean_context or ""),
        tostring(context_snapshot.anchored_context or ""),
        tostring(context_snapshot.domain_preserved_context or ""),
    }, " ")
    if context_text == "" then
        return false
    end
    for _, token in ipairs(token_set) do
        if token ~= "" and string.find(context_text, token, 1, true) then
            return true
        end
    end
    return false
end

local function apply_business_domain_prior(context_snapshot, scores, branch_scores, candidate_infos, bonuses)
    if not scores or #scores == 0 or not context_matches_token_set(context_snapshot, BUSINESS_CONTEXT_TOKENS) then
        return false
    end

    local applied = false
    for i = 1, #candidate_infos do
        local text = tostring(candidate_infos[i] and candidate_infos[i].text or "")
        local bonus = BUSINESS_CONTEXT_POSITIVE_CANDIDATES[text] or BUSINESS_CONTEXT_NEGATIVE_CANDIDATES[text] or 0.0
        bonuses[i] = bonus
        if math.abs(bonus) > SCORE_EPSILON then
            scores[i] = (scores[i] or 0.0) + bonus
            branch_scores[i] = branch_scores[i] or {}
            branch_scores[i].domain_prior = bonus
            branch_scores[i].final = scores[i]
            applied = true
        end
    end
    return applied
end

local function format_bonus_candidates(candidate_infos, bonuses)
    local preview = {}
    for i = 1, #candidate_infos do
        preview[#preview + 1] = string.format(
            "%s(%.4f)",
            tostring(candidate_infos[i] and candidate_infos[i].text or ""),
            tonumber(bonuses and bonuses[i] or 0.0) or 0.0)
    end
    return clamp_head_tail_text(table.concat(preview, " | "), DEFAULT_LOG_PREVIEW_CHARS)
end

local function top_score_drivers(branch)
    branch = branch or {}
    local drivers = {
        { name = "semantic", value = (tonumber(branch.semantic_gate or 0.0) or 0.0) * (tonumber(branch.semantic or 0.0) or 0.0) },
        { name = "preference", value = (tonumber(branch.preference_gate or 0.0) or 0.0) * (tonumber(branch.preference or 0.0) or 0.0) },
        { name = "base_frequency", value = (tonumber(branch.base_frequency_gate or 0.0) or 0.0) * (tonumber(branch.base_frequency or 0.0) or 0.0) },
        { name = "user_frequency", value = (tonumber(branch.user_frequency_gate or 0.0) or 0.0) * (tonumber(branch.user_frequency or 0.0) or 0.0) },
        { name = "continuation", value = tonumber(branch.continuation_gate or 0.0) or 0.0 },
        { name = "promotion_cap", value = tonumber(branch.promotion_cap_delta or 0.0) or 0.0 },
    }
    table.sort(drivers, function(lhs, rhs)
        return math.abs(lhs.value or 0.0) > math.abs(rhs.value or 0.0)
    end)
    local parts = {}
    for i = 1, math.min(3, #drivers) do
        parts[#parts + 1] = string.format("%s(%+.4f)", drivers[i].name, drivers[i].value or 0.0)
    end
    return table.concat(parts, ",")
end

local function promotion_cap_for_profile(env, profile)
    profile = profile or {}
    if profile.is_modal_particle then return env.modal_particle_promotion_cap end
    if profile.is_function_word then return env.function_word_promotion_cap end
    if profile.is_single_char then return env.single_char_promotion_cap end
    if profile.is_short_candidate then return env.short_candidate_promotion_cap end
    return nil
end

local function apply_short_word_promotion_caps(env, scores, branch_scores, candidate_infos, promotion_cap_bonuses)
    if not scores or #scores == 0 then
        return 0
    end

    local blocked = 0
    local original_domain_prior = tonumber(branch_scores and branch_scores[1] and branch_scores[1].domain_prior or 0.0) or 0.0
    for i = 1, #candidate_infos do
        local info = candidate_infos[i] or {}
        local profile = info.role_profile or build_candidate_role_profile(info)
        info.role_profile = profile
        local cap = promotion_cap_for_profile(env, profile)
        local candidate_domain_prior = tonumber(branch_scores and branch_scores[i] and branch_scores[i].domain_prior or 0.0) or 0.0
        local has_domain_takeover_evidence = candidate_domain_prior >= 0.08 and original_domain_prior <= -0.08
        if cap ~= nil and i > 1 and not has_domain_takeover_evidence then
            local base_score = tonumber(scores[i] or 0.0) or 0.0
            local original_score = tonumber(scores[1] or 0.0) or 0.0
            local max_score = original_score + math.max(tonumber(cap or 0.0) or 0.0, 0.0)
            if base_score > max_score then
                local delta = max_score - base_score
                scores[i] = max_score
                promotion_cap_bonuses[i] = delta
                blocked = blocked + 1
                if branch_scores[i] then
                    branch_scores[i].promotion_cap_delta = delta
                    branch_scores[i].promotion_cap = cap
                    branch_scores[i].final = scores[i]
                end
            else
                promotion_cap_bonuses[i] = 0.0
            end
        else
            promotion_cap_bonuses[i] = 0.0
            if has_domain_takeover_evidence and branch_scores[i] then
                branch_scores[i].promotion_cap_delta = 0.0
                branch_scores[i].promotion_cap_skip_reason = "business_domain_takeover"
                branch_scores[i].final = scores[i]
            end
        end
    end
    return blocked
end

local function apply_contrastive_bonuses(env, context_snapshot, scores, candidate_infos)
    local semantic_bonuses = {}
    local quality_bonuses = {}
    if not env or #candidate_infos < 2 then
        return semantic_bonuses, quality_bonuses, nil
    end

    local query_variants = build_contrastive_query_variants(context_snapshot, env.recent_tail_chars, env.context_max_chars)
    if #query_variants == 0 then
        return semantic_bonuses, quality_bonuses, nil
    end

    local groups = build_contrastive_groups(candidate_infos, env)
    if #groups == 0 then
        return semantic_bonuses, quality_bonuses, query_variants
    end

    for _, group in ipairs(groups) do
        local group_scores = nil
        local success_count = 0
        if group.semantic_weight > 0 then
            group_scores, success_count = build_weighted_similarity_scores(
                env,
                query_variants,
                group.contrast_texts,
                group.kind .. "_contrastive")
        end
        if group_scores and success_count > 0 then
            apply_centered_bonus(scores, group_scores, group.indices, group.semantic_weight, semantic_bonuses)
        end

        if group.quality_weight > 0 then
            local group_quality_values = {}
            for i = 1, #group.indices do
                group_quality_values[i] = candidate_infos[group.indices[i]].quality or 0.0
            end
            apply_centered_bonus(scores, group_quality_values, group.indices, group.quality_weight, quality_bonuses)
        end

        if env.log_enabled then
            emit_log(env, string.format(
                "contrastive[%s]: prefix_chars=%d, suffix_chars=%d, candidates=%s, focus=%s",
                tostring(group.kind or "group"),
                tonumber(group.prefix_chars or 0) or 0,
                tonumber(group.suffix_chars or 0) or 0,
                join_candidate_preview((function()
                    local texts = {}
                    for i = 1, #group.indices do
                        texts[i] = candidate_infos[group.indices[i]].text
                    end
                    return texts
                end)()),
                join_candidate_preview(group.contrast_texts or {})))
        end
    end

    return semantic_bonuses, quality_bonuses, query_variants
end

local function format_query_variants(variants)
    local preview = {}
    for i = 1, #variants do
        local variant = variants[i] or {}
        preview[#preview + 1] = string.format(
            "%s(%.2f):%s",
            tostring(variant.label or "query"),
            tonumber(variant.weight or 0.0) or 0.0,
            clamp_head_tail_text(tostring(variant.text or ""), math.max(12, math.floor(DEFAULT_LOG_PREVIEW_CHARS / 2))))
    end
    return clamp_head_tail_text(table.concat(preview, " || "), DEFAULT_LOG_PREVIEW_CHARS)
end

local function format_scored_candidates(candidates, scores, order)
    local preview = {}
    local order_list = order or {}
    if #order_list == 0 then
        for i = 1, #candidates do
            order_list[i] = i
        end
    end

    for rank, index in ipairs(order_list) do
        local candidate = get_candidate_text(candidates[index])
        local score = tonumber(scores and scores[index] or 0.0) or 0.0
        preview[#preview + 1] = string.format("#%d:%s(%.4f)", rank, candidate, score)
    end
    return clamp_head_tail_text(table.concat(preview, " | "), DEFAULT_LOG_PREVIEW_CHARS)
end

local function format_branch_candidates(candidate_infos, branch_scores, order)
    local preview = {}
    local order_list = order or {}
    if #order_list == 0 then
        for i = 1, #candidate_infos do
            order_list[i] = i
        end
    end

    for _, index in ipairs(order_list) do
        local info = candidate_infos[index] or {}
        local branch = branch_scores[index] or {}
        preview[#preview + 1] = string.format(
            "%s(f=%.4f,s=%.4f,p=%.4f,c=%.4f,g=%.4f)",
            tostring(info.text or ""),
            tonumber(branch.final or 0.0) or 0.0,
            tonumber(branch.semantic or 0.0) or 0.0,
            tonumber(branch.preference or 0.0) or 0.0,
            tonumber(branch.continuation or 0.0) or 0.0,
            tonumber(branch.dynamic_preference_factor or 0.0) or 0.0)
    end
    return clamp_head_tail_text(table.concat(preview, " | "), DEFAULT_LOG_PREVIEW_CHARS)
end

local function ensure_nonzero_scores(scores, branch_scores, candidate_infos)
    if not scores or #scores == 0 then
        return false
    end

    local has_signal = false
    for i = 1, #scores do
        if math.abs(tonumber(scores[i] or 0.0) or 0.0) > SCORE_EPSILON then
            has_signal = true
            break
        end
    end
    if has_signal then
        return false
    end

    for i = 1, #candidate_infos do
        local fallback = normalize_nonnegative_score(candidate_infos[i] and candidate_infos[i].quality or 0.0)
        scores[i] = fallback + (((#candidate_infos - i) / math.max(#candidate_infos, 1)) * 1e-4)
        branch_scores[i] = branch_scores[i] or {}
        branch_scores[i].fallback = fallback
        branch_scores[i].final = scores[i]
    end
    return true
end

local function format_coverage_candidates(candidates, ratios, bonuses)
    local preview = {}
    for i = 1, #candidates do
        preview[#preview + 1] = string.format(
            "%s(len=%d,cov=%.2f,bonus=%.4f)",
            get_candidate_text(candidates[i]),
            utf8_len(get_candidate_text(candidates[i])),
            tonumber(ratios and ratios[i] or 0.0) or 0.0,
            tonumber(bonuses and bonuses[i] or 0.0) or 0.0)
    end
    return clamp_head_tail_text(table.concat(preview, " | "), DEFAULT_LOG_PREVIEW_CHARS)
end

local function apply_top1_takeover_guard(env, current_input, scores, order, candidate_infos, context_snapshot, branch_scores)
    if not env or not scores or not order or #order < 2 then
        return order, nil
    end

    local original_first_index = 1
    local promoted_index = order[1]
    if promoted_index == original_first_index then
        return order, nil
    end

    local promoted_score = tonumber(scores[promoted_index] or 0.0) or 0.0
    local original_first_score = tonumber(scores[original_first_index] or 0.0) or 0.0
    local takeover_gain = promoted_score - original_first_score
    local takeover_distance = math.max(0, promoted_index - original_first_index)
    local promoted_profile = candidate_infos[promoted_index] and candidate_infos[promoted_index].role_profile or {}
    local promoted_domain_prior = tonumber(branch_scores and branch_scores[promoted_index] and branch_scores[promoted_index].domain_prior or 0.0) or 0.0
    local original_domain_prior = tonumber(branch_scores and branch_scores[original_first_index] and branch_scores[original_first_index].domain_prior or 0.0) or 0.0
    if promoted_domain_prior >= 0.08 and original_domain_prior <= -0.08 and takeover_gain >= 0.0 then
        return order, string.format(
            "guard_bypassed: reason=business_domain_takeover original_top1=%s(domain=%+.4f), challenger=%s(domain=%+.4f), raw_margin=%+.4f",
            tostring(candidate_infos[original_first_index] and candidate_infos[original_first_index].text or ""),
            original_domain_prior,
            tostring(candidate_infos[promoted_index] and candidate_infos[promoted_index].text or ""),
            promoted_domain_prior,
            takeover_gain)
    end
    local takeover_threshold =
        env.top1_takeover_margin + (takeover_distance * env.top1_takeover_distance_margin)
    local guard_reason = "margin_below_threshold"
    if promoted_profile.is_modal_particle then
        takeover_threshold = takeover_threshold + math.max(env.modal_particle_promotion_cap, 0.0)
        guard_reason = "challenger_is_modal_particle"
    elseif promoted_profile.is_function_word then
        takeover_threshold = takeover_threshold + math.max(env.function_word_promotion_cap, 0.0)
        guard_reason = "challenger_is_function_word"
    elseif promoted_profile.is_single_char then
        takeover_threshold = takeover_threshold + math.max(env.single_char_promotion_cap, 0.0)
        guard_reason = "challenger_is_single_char"
    elseif promoted_profile.is_short_candidate then
        takeover_threshold = takeover_threshold + math.max(env.short_candidate_promotion_cap, 0.0)
        guard_reason = "challenger_is_short_candidate"
    end
    local current_input_letters = current_input_letter_count(current_input or "")
    if current_input_letters >= env.top1_takeover_long_input_min_letters then
        takeover_threshold = takeover_threshold + env.top1_takeover_long_input_extra_margin
    end

    local context_confidence = tonumber(context_snapshot and context_snapshot.context_confidence or 0.0) or 0.0
    if context_confidence < DEFAULT_MIN_CONTEXT_CONFIDENCE then
        takeover_threshold = takeover_threshold + DEFAULT_LOW_CONTEXT_TAKEOVER_EXTRA_MARGIN
    elseif context_confidence >= DEFAULT_STRONG_CONTEXT_CONFIDENCE then
        takeover_threshold = math.max(
            0.0,
            takeover_threshold - DEFAULT_STRONG_CONTEXT_TAKEOVER_MARGIN_DISCOUNT)
    elseif context_confidence >= DEFAULT_MEDIUM_CONTEXT_CONFIDENCE then
        takeover_threshold = math.max(
            0.0,
            takeover_threshold - DEFAULT_MEDIUM_CONTEXT_TAKEOVER_MARGIN_DISCOUNT)
    end

    if takeover_gain >= takeover_threshold then
        return order, nil
    end

    local guarded_order = { original_first_index }
    for i = 1, #order do
        if order[i] ~= original_first_index then
            guarded_order[#guarded_order + 1] = order[i]
        end
    end

    local detail = string.format(
        "guard_triggered: original_top1=%s(%.4f), challenger=%s(%.4f), raw_margin=%+.4f, threshold=%.4f, distance=%d, context_confidence=%.2f, guard_reason=%s, challenger_role=%s, major_drivers=%s",
        tostring(candidate_infos[original_first_index] and candidate_infos[original_first_index].text or ""),
        original_first_score,
        tostring(candidate_infos[promoted_index] and candidate_infos[promoted_index].text or ""),
        promoted_score,
        takeover_gain,
        takeover_threshold,
        takeover_distance,
        context_confidence,
        guard_reason,
        candidate_role_label(promoted_profile),
        top_score_drivers(branch_scores and branch_scores[promoted_index] or nil))
    return guarded_order, detail
end

local function make_signature(query_variants, candidates)
    local variant_parts = {}
    for i = 1, #query_variants do
        local variant = query_variants[i] or {}
        variant_parts[#variant_parts + 1] = string.format(
            "%s@%.3f",
            tostring(variant.text or ""),
            tonumber(variant.weight or 0.0) or 0.0)
    end
    local candidate_parts = {}
    for i = 1, #candidates do
        local candidate = candidates[i]
        if type(candidate) == "table" then
            candidate_parts[#candidate_parts + 1] = string.format(
                "%s@%.4f@%s",
                tostring(candidate.text or ""),
                tonumber(candidate.quality or 0.0) or 0.0,
                tostring(candidate.type or ""))
        else
            candidate_parts[#candidate_parts + 1] = tostring(candidate or "")
        end
    end
    return table.concat({
        table.concat(variant_parts, "\29"),
        "\30",
        table.concat(candidate_parts, "\31"),
    })
end

local function maybe_prewarm_rerank_context(env, trigger)
    if not env or not env.backend_ready or not env.core or type(env.core.warm_query) ~= "function" then
        return
    end

    env.current_trace_id = next_trace_id(env)
    local context_snapshot = build_context_snapshot(env)
    emit_context_snapshot_logs(env, "prewarm", context_snapshot)
    local query_variants = build_query_variants(context_snapshot, env.recent_tail_chars, env.context_max_chars)
    if #query_variants == 0 then
        return
    end

    local warm_signature_parts = {}
    for i = 1, #query_variants do
        warm_signature_parts[#warm_signature_parts + 1] = query_variants[i].text
    end
    local warm_signature = table.concat(warm_signature_parts, "\29")
    if env.last_prewarm_signature == warm_signature then
        return
    end

    local started_at = rime_api and rime_api.get_time_ms and rime_api.get_time_ms() or nil
    local warmed_any = false
    for i = 1, #query_variants do
        local variant = query_variants[i]
        local ok, err = env.core.warm_query(variant.text)
        if ok then
            warmed_any = true
        elseif env.log_enabled then
            emit_log(env, string.format(
                "prewarm skipped, trigger=%s, query_label=%s, error=%s",
                tostring(trigger or "unknown"),
                tostring(variant.label or "query"),
                tostring(err or "unknown error")))
        end
    end
    local finished_at = rime_api and rime_api.get_time_ms and rime_api.get_time_ms() or nil
    if not warmed_any then
        return
    end

    env.last_prewarm_signature = warm_signature
    if env.log_enabled then
        local elapsed_ms = (started_at and finished_at) and (finished_at - started_at) or -1
        emit_log(env,
            string.format(
                "prewarm done, trigger=%s, clean_context=%s, query_variants=%s, context_chars=%d, elapsed_ms=%d",
                tostring(trigger or "unknown"),
                clamp_head_tail_text(context_snapshot.clean_context or "", DEFAULT_LOG_PREVIEW_CHARS),
                format_query_variants(query_variants),
                utf8_len(context_snapshot.clean_context or ""),
                elapsed_ms))
    end
end

join_candidate_preview = function(candidates)
    local preview = {}
    for i = 1, #candidates do
        preview[#preview + 1] = get_candidate_text(candidates[i])
    end
    return table.concat(preview, " | ")
end

local function clone_text_array(values)
    local cloned = {}
    for i = 1, #values do
        cloned[i] = values[i]
    end
    return cloned
end

local function should_preserve_first_candidate(env, candidate)
    if not candidate then
        return false
    end

    local text = trim_spaces(candidate.text or "")
    if text == "" then
        return false
    end

    local min_chars = (env and env.preserve_first_min_chars) or DEFAULT_PRESERVE_FIRST_MIN_CHARS
    if min_chars <= 0 then
        return false
    end
    return utf8_len(text) >= min_chars
end

local function remember_feedback_session(env, fixed_first_text, reordered_texts)
    env.last_feedback_session = {
        fixed_first = trim_spaces(fixed_first_text or ""),
        reranked = clone_text_array(reordered_texts or {}),
    }
end

clear_feedback_session = function(env)
    env.last_feedback_session = nil
end

build_feedback_for_commit = function(env, committed_text)
    committed_text = trim_spaces(committed_text or "")
    if committed_text == "" then
        return nil
    end

    local session = env.last_feedback_session
    if not session then
        return {
            positive = committed_text,
            negatives = {},
            matched = false,
        }
    end

    local reranked = session.reranked or {}
    local matched_index = nil
    for i = 1, #reranked do
        if reranked[i] == committed_text then
            matched_index = i
            break
        end
    end

    local negatives = {}
    if matched_index then
        local negative_count = math.min(matched_index - 1, env.max_negative_candidates)
        for i = 1, negative_count do
            negatives[#negatives + 1] = reranked[i]
        end
        return {
            positive = committed_text,
            negatives = negatives,
            matched = true,
        }
    end

    return {
        positive = committed_text,
        negatives = {},
        matched = session.fixed_first == committed_text,
    }
end

apply_user_feedback = function(env, committed_text, negative_candidates)
    if env.preference_sync_disabled or not env.core then
        return nil, "preference sync disabled"
    end

    negative_candidates = negative_candidates or {}
    if type(env.core.apply_user_feedback) == "function" then
        return env.core.apply_user_feedback(committed_text, negative_candidates)
    end
    if type(env.core.update_user_preference) == "function" then
        return env.core.update_user_preference(committed_text)
    end

    env.preference_sync_disabled = true
    return nil, "no preference feedback api available"
end

local function rerank_candidates(env, context_snapshot, current_input, candidate_infos)
    if not env.backend_ready or not env.core then
        return nil
    end

    env.current_trace_id = next_trace_id(env)

    local context_confidence = tonumber(context_snapshot and context_snapshot.context_confidence or 0.0) or 0.0
    local low_context_confidence = context_confidence < DEFAULT_MIN_CONTEXT_CONFIDENCE

    local query_variants = build_query_variants(context_snapshot, env.recent_tail_chars, env.context_max_chars)
    if #query_variants == 0 then
        if env.log_enabled then
            emit_log(env, "score_status=skipped reason=empty_history_context")
        end
        return nil
    end

    local candidate_texts = extract_candidate_texts(candidate_infos)
    local primary_query = query_variants[1] and query_variants[1].text or ""
    local signature = make_signature(query_variants, candidate_infos)
    if signature == env.last_signature and env.last_order then
        if env.log_enabled then
            emit_log(env,
                string.format(
                    "cache hit, ime_input=%s, clean_context=%s, query_variants=%s, before=%s",
                    tostring(current_input),
                    clamp_head_tail_text(context_snapshot and context_snapshot.clean_context or "", DEFAULT_LOG_PREVIEW_CHARS),
                    format_query_variants(query_variants),
                    join_candidate_preview(candidate_infos)))
        end
        return env.last_order
    end

    local started_at = rime_api and rime_api.get_time_ms and rime_api.get_time_ms() or nil
    local breakdown_scores, successful_variants = build_breakdown_scores(env, query_variants, candidate_texts, "semantic")
    if not breakdown_scores or successful_variants <= 0 then
        log_warn("[alpha_rerank] compute_score_breakdowns failed for all query variants")
        return nil
    end
    local finished_at = rime_api and rime_api.get_time_ms and rime_api.get_time_ms() or nil

    local candidate_count = #breakdown_scores
    local expected_candidate_chars = estimate_expected_candidate_chars(current_input)
    local scores = {}
    local branch_scores = {}
    local order_prior_bonuses = {}
    local quality_prior_bonuses = {}
    local user_frequency_bonuses = {}
    local contrastive_semantic_bonuses = {}
    local contrastive_quality_bonuses = {}
    local domain_prior_bonuses = {}
    local contrastive_query_variants = nil
    local coverage_ratios = {}
    local coverage_bonuses = {}
    local continuation_bonuses = {}
    local gate_semantic_bonuses = {}
    local promotion_cap_bonuses = {}

    for i = 1, candidate_count do
        local info = candidate_infos[i]
        info.role_profile = build_candidate_role_profile(info)
        local row = breakdown_scores[i] or {}
        local semantic_score = normalize_branch_score(row.semantic_score)
        local preference_score = normalize_branch_score(row.preference_score)
        local user_frequency_score = normalize_nonnegative_score(row.user_frequency_score)
        local dynamic_preference_factor = clamp01(row.dynamic_preference_factor)
        local continuation_bonus, semantic_adjustment = compute_continuation_prior(
            env,
            info,
            context_snapshot,
            current_input,
            expected_candidate_chars)

        continuation_bonuses[i] = continuation_bonus
        gate_semantic_bonuses[i] = semantic_adjustment

        local semantic_gate = env.gate_semantic_weight + semantic_adjustment
        local continuation_gate = env.gate_continuation_weight + continuation_bonus
        local preference_gate = env.gate_preference_weight * (0.4 + (0.6 * dynamic_preference_factor))
        local base_frequency_gate = env.base_frequency_weight
        local user_frequency_gate = env.gate_user_frequency_weight

        if info.role_profile and info.role_profile.is_content_word then
            semantic_gate = semantic_gate + env.content_word_semantic_boost
        end
        if info.role_profile and info.role_profile.is_modal_particle then
            continuation_gate = continuation_gate * env.modal_particle_continuation_scale
            user_frequency_gate = user_frequency_gate * env.modal_particle_user_frequency_scale
            base_frequency_gate = base_frequency_gate * 0.50
        elseif info.role_profile and info.role_profile.is_function_word then
            continuation_gate = continuation_gate * env.function_word_continuation_scale
            user_frequency_gate = user_frequency_gate * env.function_word_user_frequency_scale
            base_frequency_gate = base_frequency_gate * 0.60
        elseif info.role_profile and info.role_profile.is_single_char then
            continuation_gate = continuation_gate * env.single_char_continuation_scale
            user_frequency_gate = user_frequency_gate * env.single_char_user_frequency_scale
            base_frequency_gate = base_frequency_gate * 0.70
        elseif info.role_profile and info.role_profile.is_short_candidate then
            continuation_gate = continuation_gate * env.short_candidate_continuation_scale
            user_frequency_gate = user_frequency_gate * env.short_candidate_user_frequency_scale
        end

        if semantic_gate < 0.05 then semantic_gate = 0.05 end
        if continuation_gate < 0.0 then continuation_gate = 0.0 end
        if preference_gate < 0.0 then preference_gate = 0.0 end
        if base_frequency_gate < 0.0 then base_frequency_gate = 0.0 end
        if user_frequency_gate < 0.0 then user_frequency_gate = 0.0 end

        scores[i] =
            (semantic_gate * semantic_score) +
            (preference_gate * preference_score) +
            (base_frequency_gate * normalize_nonnegative_score(info.quality)) +
            (user_frequency_gate * user_frequency_score) +
            continuation_gate
        branch_scores[i] = {
            semantic = semantic_score,
            preference = preference_score,
            base_frequency = normalize_nonnegative_score(info.quality),
            user_frequency_raw = user_frequency_score,
            user_frequency = user_frequency_score,
            continuation = continuation_bonus,
            semantic_gate = semantic_gate,
            preference_gate = preference_gate,
            base_frequency_gate = base_frequency_gate,
            user_frequency_gate = user_frequency_gate,
            continuation_gate = continuation_gate,
            dynamic_preference_factor = dynamic_preference_factor,
            final = scores[i],
        }
    end

    if candidate_count > 1 then
        for i = 1, candidate_count do
            local order_prior = (candidate_count - i + 1) / candidate_count
            local order_bonus = env.gate_order_weight * env.order_prior_weight * order_prior
            order_prior_bonuses[i] = order_bonus
            scores[i] = scores[i] + order_bonus
            branch_scores[i].final = scores[i]
        end
    end
    local quality_weight_backup = env.quality_prior_weight
    env.quality_prior_weight = env.gate_quality_weight * quality_weight_backup
    apply_quality_prior(scores, candidate_infos, env, quality_prior_bonuses)
    env.quality_prior_weight = quality_weight_backup
    apply_user_frequency_prior(scores, branch_scores, candidate_infos, env, user_frequency_bonuses)
    if expected_candidate_chars > 0 and env.input_coverage_weight > 0 then
        for i = 1, candidate_count do
            local coverage_bonus, coverage_ratio = compute_input_coverage_bonus(
                env,
                current_input,
                candidate_texts[i],
                expected_candidate_chars)
            coverage_bonus = coverage_bonus * env.gate_coverage_weight
            coverage_ratios[i] = coverage_ratio
            coverage_bonuses[i] = coverage_bonus
            scores[i] = scores[i] + coverage_bonus
            branch_scores[i].final = scores[i]
        end
    end
    contrastive_semantic_bonuses, contrastive_quality_bonuses, contrastive_query_variants =
        apply_contrastive_bonuses(env, context_snapshot, scores, candidate_infos)
    apply_business_domain_prior(context_snapshot, scores, branch_scores, candidate_infos, domain_prior_bonuses)

    for i = 1, candidate_count do
        branch_scores[i].final = tonumber(scores[i] or 0.0) or 0.0
    end
    local zero_score_guard_applied = ensure_nonzero_scores(scores, branch_scores, candidate_infos)
    local promotion_cap_blocked_count =
        apply_short_word_promotion_caps(env, scores, branch_scores, candidate_infos, promotion_cap_bonuses)

    local order = {}
    for i = 1, candidate_count do
        order[i] = i
    end

    table.sort(order, function(lhs, rhs)
        local left_score = scores[lhs] or 0.0
        local right_score = scores[rhs] or 0.0
        if math.abs(left_score - right_score) < 1e-9 then
            return lhs < rhs
        end
        return left_score > right_score
    end)
    local raw_order = clone_text_array(order)

    local guarded_order, takeover_guard_detail =
        apply_top1_takeover_guard(env, current_input, scores, order, candidate_infos, context_snapshot, branch_scores)
    order = guarded_order or order

    env.last_signature = signature
    env.last_order = order
    local elapsed_ms = (started_at and finished_at) and (finished_at - started_at) or -1
    if env.log_enabled then
        emit_log(env,
            string.format(
                "rerank done, ime_input=%s, clean_context=%s, primary_query=%s, query_variants=%s, contrastive_query_variants=%s, context_chars=%d, pool=%d, expected_candidate_chars=%d, elapsed_ms=%d",
                tostring(current_input),
                clamp_head_tail_text(context_snapshot and context_snapshot.clean_context or "", DEFAULT_LOG_PREVIEW_CHARS),
                clamp_head_tail_text(primary_query, DEFAULT_LOG_PREVIEW_CHARS),
                format_query_variants(query_variants),
                format_query_variants(contrastive_query_variants or {}),
                utf8_len(primary_query),
                #candidate_infos,
                expected_candidate_chars,
                elapsed_ms))
        emit_log(env, string.format("context_confidence=%.2f", context_confidence))
        emit_log(env, string.format(
            "accept_decision=%s reason=%s",
            low_context_confidence and "abstain" or "accept",
            low_context_confidence and "low_context_confidence" or "sufficient_context_confidence"))
        emit_log(env, "candidate_details=" .. format_candidate_quality_preview(candidate_infos))
        emit_log(env, "raw_scores=" .. format_scored_candidates(candidate_infos, scores, raw_order))
        emit_log(env, "guarded_scores=" .. format_scored_candidates(candidate_infos, scores, order))
        emit_log(env, string.format(
            "raw_top1=%s guarded_top1=%s guard_triggered=%s promotion_cap_blocked=%d",
            tostring(candidate_infos[raw_order[1] or 0] and candidate_infos[raw_order[1]].text or ""),
            tostring(candidate_infos[order[1] or 0] and candidate_infos[order[1]].text or ""),
            tostring((raw_order[1] or 0) ~= (order[1] or 0)),
            promotion_cap_blocked_count))
        emit_log(env, "branches=" .. format_branch_candidates(candidate_infos, branch_scores, order))
        emit_log(env, "order_prior=" .. format_bonus_candidates(candidate_infos, order_prior_bonuses))
        emit_log(env, "quality_prior=" .. format_bonus_candidates(candidate_infos, quality_prior_bonuses))
        emit_log(env, "user_frequency_prior=" .. format_bonus_candidates(candidate_infos, user_frequency_bonuses))
        emit_log(env, "contrastive_semantic=" .. format_bonus_candidates(candidate_infos, contrastive_semantic_bonuses))
        emit_log(env, "contrastive_quality=" .. format_bonus_candidates(candidate_infos, contrastive_quality_bonuses))
        emit_log(env, "domain_prior=" .. format_bonus_candidates(candidate_infos, domain_prior_bonuses))
        emit_log(env, "continuation=" .. format_bonus_candidates(candidate_infos, continuation_bonuses))
        emit_log(env, "semantic_gate_adjust=" .. format_bonus_candidates(candidate_infos, gate_semantic_bonuses))
        emit_log(env, "promotion_cap=" .. format_bonus_candidates(candidate_infos, promotion_cap_bonuses))
        if takeover_guard_detail then
            emit_log(env, takeover_guard_detail)
        end
        if zero_score_guard_applied then
            emit_log(env, "score_status=fallback reason=all_model_scores_zero")
        elseif low_context_confidence then
            emit_log(env, string.format(
                "score_status=abstain reason=low_context_confidence context_confidence=%.2f accept_decision=abstain",
                context_confidence))
        else
            emit_log(env, "score_status=valid accept_decision=accept")
        end
        if expected_candidate_chars > 0 then
            emit_log(env, "coverage=" .. format_coverage_candidates(candidate_infos, coverage_ratios, coverage_bonuses))
        end
    end
    return order
end

function M.init(env)
    local config = env.engine.schema.config
    env.enabled = config:get_bool("alpha_rerank/enabled")
    if env.enabled == nil then env.enabled = false end

    env.max_candidates = config:get_int("alpha_rerank/max_candidates") or DEFAULT_MAX_CANDIDATES
    env.max_negative_candidates = config:get_int("alpha_rerank/max_negative_candidates") or
        DEFAULT_MAX_NEGATIVE_CANDIDATES
    env.context_max_chars = config:get_int("alpha_rerank/context_max_chars") or DEFAULT_CONTEXT_MAX_CHARS
    env.recent_tail_chars = config:get_int("alpha_rerank/recent_tail_chars") or DEFAULT_RECENT_TAIL_CHARS
    env.order_prior_weight = config:get_double("alpha_rerank/order_prior_weight") or DEFAULT_ORDER_PRIOR_WEIGHT
    env.input_coverage_weight = config:get_double("alpha_rerank/input_coverage_weight") or DEFAULT_INPUT_COVERAGE_WEIGHT
    env.quality_prior_weight = config:get_double("alpha_rerank/quality_prior_weight") or DEFAULT_QUALITY_PRIOR_WEIGHT
    env.phrase_type_bonus = config:get_double("alpha_rerank/phrase_type_bonus") or DEFAULT_PHRASE_TYPE_BONUS
    env.contrastive_core_weight = config:get_double("alpha_rerank/contrastive_core_weight") or
        DEFAULT_CONTRASTIVE_CORE_WEIGHT
    env.contrastive_quality_weight = config:get_double("alpha_rerank/contrastive_quality_weight") or
        DEFAULT_CONTRASTIVE_QUALITY_WEIGHT
    env.shortlist_contrastive_weight = config:get_double("alpha_rerank/shortlist_contrastive_weight") or
        DEFAULT_SHORTLIST_CONTRASTIVE_WEIGHT
    env.gate_semantic_weight = config:get_double("alpha_rerank/gate_semantic_weight") or
        DEFAULT_GATE_SEMANTIC_WEIGHT
    env.gate_preference_weight = config:get_double("alpha_rerank/gate_preference_weight") or
        DEFAULT_GATE_PREFERENCE_WEIGHT
    env.gate_order_weight = config:get_double("alpha_rerank/gate_order_weight") or
        DEFAULT_GATE_ORDER_WEIGHT
    env.gate_quality_weight = config:get_double("alpha_rerank/gate_quality_weight") or
        DEFAULT_GATE_QUALITY_WEIGHT
    env.gate_user_frequency_weight = config:get_double("alpha_rerank/gate_user_frequency_weight") or
        DEFAULT_GATE_USER_FREQUENCY_WEIGHT
    env.gate_coverage_weight = config:get_double("alpha_rerank/gate_coverage_weight") or
        DEFAULT_GATE_COVERAGE_WEIGHT
    env.gate_continuation_weight = config:get_double("alpha_rerank/gate_continuation_weight") or
        DEFAULT_GATE_CONTINUATION_WEIGHT
    env.base_frequency_weight = config:get_double("alpha_rerank/base_frequency_weight") or
        DEFAULT_BASE_FREQUENCY_WEIGHT
    env.user_frequency_short_candidate_boost =
        config:get_double("alpha_rerank/user_frequency_short_candidate_boost") or
        DEFAULT_USER_FREQUENCY_SHORT_CANDIDATE_BOOST
    env.user_frequency_function_word_boost =
        config:get_double("alpha_rerank/user_frequency_function_word_boost") or
        DEFAULT_USER_FREQUENCY_FUNCTION_WORD_BOOST
    env.function_word_continuation_boost =
        config:get_double("alpha_rerank/function_word_continuation_boost") or
        DEFAULT_FUNCTION_WORD_CONTINUATION_BOOST
    env.function_word_semantic_penalty =
        config:get_double("alpha_rerank/function_word_semantic_penalty") or
        DEFAULT_FUNCTION_WORD_SEMANTIC_PENALTY
    env.single_char_continuation_boost =
        config:get_double("alpha_rerank/single_char_continuation_boost") or
        DEFAULT_SINGLE_CHAR_CONTINUATION_BOOST
    env.short_candidate_continuation_boost =
        config:get_double("alpha_rerank/short_candidate_continuation_boost") or
        DEFAULT_SHORT_CANDIDATE_CONTINUATION_BOOST
    env.long_candidate_semantic_boost =
        config:get_double("alpha_rerank/long_candidate_semantic_boost") or
        DEFAULT_LONG_CANDIDATE_SEMANTIC_BOOST
    env.low_context_semantic_penalty =
        config:get_double("alpha_rerank/low_context_semantic_penalty") or
        DEFAULT_LOW_CONTEXT_SEMANTIC_PENALTY
    env.strong_context_continuation_boost =
        config:get_double("alpha_rerank/strong_context_continuation_boost") or
        DEFAULT_STRONG_CONTEXT_CONTINUATION_BOOST
    env.content_word_semantic_boost = config:get_double("alpha_rerank/content_word_semantic_boost") or
        DEFAULT_CONTENT_WORD_SEMANTIC_BOOST
    env.modal_particle_promotion_cap = config:get_double("alpha_rerank/modal_particle_promotion_cap") or
        DEFAULT_MODAL_PARTICLE_PROMOTION_CAP
    env.function_word_promotion_cap = config:get_double("alpha_rerank/function_word_promotion_cap") or
        DEFAULT_FUNCTION_WORD_PROMOTION_CAP
    env.single_char_promotion_cap = config:get_double("alpha_rerank/single_char_promotion_cap") or
        DEFAULT_SINGLE_CHAR_PROMOTION_CAP
    env.short_candidate_promotion_cap = config:get_double("alpha_rerank/short_candidate_promotion_cap") or
        DEFAULT_SHORT_CANDIDATE_PROMOTION_CAP
    env.modal_particle_user_frequency_scale = config:get_double("alpha_rerank/modal_particle_user_frequency_scale") or
        DEFAULT_MODAL_PARTICLE_USER_FREQUENCY_SCALE
    env.function_word_user_frequency_scale = config:get_double("alpha_rerank/function_word_user_frequency_scale") or
        DEFAULT_FUNCTION_WORD_USER_FREQUENCY_SCALE
    env.single_char_user_frequency_scale = config:get_double("alpha_rerank/single_char_user_frequency_scale") or
        DEFAULT_SINGLE_CHAR_USER_FREQUENCY_SCALE
    env.short_candidate_user_frequency_scale = config:get_double("alpha_rerank/short_candidate_user_frequency_scale") or
        DEFAULT_SHORT_CANDIDATE_USER_FREQUENCY_SCALE
    env.user_frequency_tie_break_gap = config:get_double("alpha_rerank/user_frequency_tie_break_gap") or
        DEFAULT_USER_FREQUENCY_TIE_BREAK_GAP
    env.generic_continuation_scale = config:get_double("alpha_rerank/generic_continuation_scale") or
        DEFAULT_GENERIC_CONTINUATION_SCALE
    env.function_word_continuation_scale = config:get_double("alpha_rerank/function_word_continuation_scale") or
        DEFAULT_FUNCTION_WORD_CONTINUATION_SCALE
    env.modal_particle_continuation_scale = config:get_double("alpha_rerank/modal_particle_continuation_scale") or
        DEFAULT_MODAL_PARTICLE_CONTINUATION_SCALE
    env.single_char_continuation_scale = config:get_double("alpha_rerank/single_char_continuation_scale") or
        DEFAULT_SINGLE_CHAR_CONTINUATION_SCALE
    env.short_candidate_continuation_scale = config:get_double("alpha_rerank/short_candidate_continuation_scale") or
        DEFAULT_SHORT_CANDIDATE_CONTINUATION_SCALE
    env.top1_takeover_margin = config:get_double("alpha_rerank/top1_takeover_margin") or
        DEFAULT_TOP1_TAKEOVER_MARGIN
    env.top1_takeover_distance_margin =
        config:get_double("alpha_rerank/top1_takeover_distance_margin") or
        DEFAULT_TOP1_TAKEOVER_DISTANCE_MARGIN
    env.top1_takeover_long_input_min_letters =
        config:get_int("alpha_rerank/top1_takeover_long_input_min_letters") or
        DEFAULT_TOP1_TAKEOVER_LONG_INPUT_MIN_LETTERS
    env.top1_takeover_long_input_extra_margin =
        config:get_double("alpha_rerank/top1_takeover_long_input_extra_margin") or
        DEFAULT_TOP1_TAKEOVER_LONG_INPUT_EXTRA_MARGIN
    env.max_contrastive_candidate_chars = config:get_int("alpha_rerank/max_contrastive_candidate_chars") or
        DEFAULT_MAX_CONTRASTIVE_CANDIDATE_CHARS
    env.shortlist_contrastive_max_chars = config:get_int("alpha_rerank/shortlist_contrastive_max_chars") or
        DEFAULT_SHORTLIST_MAX_CANDIDATE_CHARS
    env.preserve_first_min_chars = config:get_int("alpha_rerank/preserve_first_min_chars") or
        DEFAULT_PRESERVE_FIRST_MIN_CHARS
    env.prefer_sentence_boundary = config:get_bool("alpha_rerank/prefer_sentence_boundary")
    if env.prefer_sentence_boundary == nil then env.prefer_sentence_boundary = true end
    env.log_enabled = config:get_bool("alpha_rerank/log_enabled")
    if env.log_enabled == nil then
        local audit_enabled = os and os.getenv and os.getenv("WEASEL_SERVER_AUDIT_ENABLED") or ""
        env.log_enabled = audit_enabled == "1"
    end
    env.log_file_path = resolve_path(config:get_string("alpha_rerank/log_path") or "")
    if env.log_file_path == "" and os and os.getenv then
        env.log_file_path = resolve_path(os.getenv("WEASEL_SERVER_AUDIT_LOG_PATH") or "")
    end
    if env.log_file_path == "" and rime_api and rime_api.get_user_data_dir then
        local user_data_dir = trim_spaces(rime_api.get_user_data_dir() or "")
        if user_data_dir ~= "" then
            env.log_file_path = user_data_dir .. "/alpha_rerank.log"
        end
    end
    env.log_init_file_path = resolve_path(config:get_string("alpha_rerank/init_log_path") or "")
    env.log_rerank_file_path = resolve_path(config:get_string("alpha_rerank/rerank_log_path") or "")
    env.log_eval_file_path = resolve_path(config:get_string("alpha_rerank/eval_log_path") or "")
    if env.log_init_file_path == "" then env.log_init_file_path = sibling_log_path(env.log_file_path, "alpha_init.log") end
    if env.log_rerank_file_path == "" then env.log_rerank_file_path = sibling_log_path(env.log_file_path, "alpha_rerank.log") end
    if env.log_eval_file_path == "" then env.log_eval_file_path = sibling_log_path(env.log_file_path, "alpha_eval.log") end
    env.log_session_id = os and os.date and os.date("%Y%m%d-%H%M%S") or tostring(math.floor((rime_api and rime_api.get_time_ms and rime_api.get_time_ms() or 0)))
    env.current_trace_id = "init"
    env.log_phase = "init"
    env.log_file_failed = false
    env.trace_sequence = 0

    env.tags = load_tags(config)
    env.core = alpha_core
    env.backend_ready = false
    env.last_signature = nil
    env.last_order = nil
    env.preference_sync_disabled = false
    env.preference_history_snapshot = get_commit_history_segments(env)
    env.last_feedback_session = nil
    env.last_prewarm_signature = nil
    env.commit_notifier = nil
    env.last_context_log_signature = nil

    if not env.enabled then
        return
    end

    if not env.core then
        log_warn("[alpha_rerank] alpha_rerank_core module is unavailable; filter will be bypassed")
        return
    end

    local config_path = resolve_path(config:get_string("alpha_rerank/config_path") or "")
    local dll_path = resolve_path(config:get_string("alpha_rerank/dll_path") or "")
    if config_path == "" then
        log_warn("[alpha_rerank] alpha_rerank/config_path is empty; filter will be bypassed")
        return
    end

    local ok, err = env.core.configure({
        config_path = config_path,
        dll_path = dll_path,
    })
    if ok then
        env.backend_ready = true
        if env.engine and env.engine.context and env.engine.context.commit_notifier then
            env.commit_notifier = env.engine.context.commit_notifier:connect(function(_)
                maybe_prewarm_rerank_context(env, "commit")
            end)
        end
        emit_log(env, "configured successfully")
        emit_log(env, "config_path=" .. config_path)
        emit_log(env, "dll_path=" .. (dll_path ~= "" and dll_path or "<auto>"))
        emit_log(env, "log_path=" .. (env.log_file_path ~= "" and env.log_file_path or "<disabled>"))
        emit_log(env, string.format(
            "split_logs: init=%s, rerank=%s, eval=%s",
            tostring(env.log_init_file_path or ""),
            tostring(env.log_rerank_file_path or ""),
            tostring(env.log_eval_file_path or "")))
        emit_log(env,
            string.format(
                "settings: max_candidates=%d, max_negative_candidates=%d, context_max_chars=%d, recent_tail_chars=%d, order_prior_weight=%.3f, input_coverage_weight=%.3f, quality_prior_weight=%.3f, phrase_type_bonus=%.3f, contrastive_core_weight=%.3f, contrastive_quality_weight=%.3f, shortlist_contrastive_weight=%.3f, gate_semantic_weight=%.3f, gate_preference_weight=%.3f, gate_order_weight=%.3f, gate_quality_weight=%.3f, gate_user_frequency_weight=%.3f, gate_coverage_weight=%.3f, gate_continuation_weight=%.3f, base_frequency_weight=%.3f, preserve_first_min_chars=%d",
                env.max_candidates,
                env.max_negative_candidates,
                env.context_max_chars,
                env.recent_tail_chars,
                env.order_prior_weight,
                env.input_coverage_weight,
                env.quality_prior_weight,
                env.phrase_type_bonus,
                env.contrastive_core_weight,
                env.contrastive_quality_weight,
                env.shortlist_contrastive_weight,
                env.gate_semantic_weight,
                env.gate_preference_weight,
                env.gate_order_weight,
                env.gate_quality_weight,
                env.gate_user_frequency_weight,
                env.gate_coverage_weight,
                env.gate_continuation_weight,
                env.base_frequency_weight,
                env.preserve_first_min_chars))
        emit_log(env,
            string.format(
                "stability: top1_takeover_margin=%.3f, top1_takeover_distance_margin=%.3f, top1_takeover_long_input_min_letters=%d, top1_takeover_long_input_extra_margin=%.3f",
                env.top1_takeover_margin,
                env.top1_takeover_distance_margin,
                env.top1_takeover_long_input_min_letters,
                env.top1_takeover_long_input_extra_margin))
        emit_log(env,
            string.format(
                "candidate_type_gate: modal_cap=%.3f, function_cap=%.3f, single_cap=%.3f, short_cap=%.3f, uf_scales=modal:%.2f/function:%.2f/single:%.2f/short:%.2f, continuation_scales=modal:%.2f/function:%.2f/single:%.2f/short:%.2f/generic:%.2f",
                env.modal_particle_promotion_cap,
                env.function_word_promotion_cap,
                env.single_char_promotion_cap,
                env.short_candidate_promotion_cap,
                env.modal_particle_user_frequency_scale,
                env.function_word_user_frequency_scale,
                env.single_char_user_frequency_scale,
                env.short_candidate_user_frequency_scale,
                env.modal_particle_continuation_scale,
                env.function_word_continuation_scale,
                env.single_char_continuation_scale,
                env.short_candidate_continuation_scale,
                env.generic_continuation_scale))
        env.log_phase = "rerank"
    else
        log_warn("[alpha_rerank] configure failed: " .. tostring(err or "unknown error"))
    end
end

function M.func(input, env)
    if not env.enabled or not env.backend_ready then
        for cand in input:iter() do yield(cand) end
        return
    end

    local context = env.engine.context
    if wanxiang.is_function_mode_active(context) then
        for cand in input:iter() do yield(cand) end
        return
    end

    sync_user_preference(env)
    maybe_prewarm_rerank_context(env, "filter")

    local seg = context.composition and context.composition:back() or nil
    if not seg or not tags_match(seg, env) then
        for cand in input:iter() do yield(cand) end
        return
    end

    local current_input = context.input or ""
    if current_input == "" then
        for cand in input:iter() do yield(cand) end
        return
    end

    local all_candidates = {}
    for cand in input:iter() do
        table.insert(all_candidates, cand)
    end

    if #all_candidates < 2 then
        for _, cand in ipairs(all_candidates) do yield(cand) end
        return
    end

    local preserve_first = should_preserve_first_candidate(env, all_candidates[1])
    local fixed_first = preserve_first and all_candidates[1] or nil
    local rerank_pool = {}
    local pool_limit = math.min(#all_candidates, env.max_candidates)
    local pool_start = preserve_first and 2 or 1
    for i = pool_start, pool_limit do
        local cand = all_candidates[i]
        if cand and cand.text and cand.text ~= "" then
            rerank_pool[#rerank_pool + 1] = cand
        end
    end

    local candidate_infos = build_candidate_infos(rerank_pool)
    if #candidate_infos < 1 then
        for _, cand in ipairs(all_candidates) do yield(cand) end
        return
    end

    local context_snapshot = build_context_snapshot(env)
    emit_context_snapshot_logs(env, "filter", context_snapshot)
    local rerank_context = build_rerank_context(context_snapshot, env.recent_tail_chars, env.context_max_chars)
    if env.log_enabled then
        emit_log(env,
            string.format(
                "ime_input=%s, preserve_first=%s, fixed_first=%s, history_chars=%d, rerank_pool=%d, rerank_context=%s",
                tostring(current_input),
                tostring(preserve_first),
                tostring(fixed_first and fixed_first.text or ""),
                utf8_len(context_snapshot.clean_context or ""),
                #candidate_infos,
                clamp_head_tail_text(rerank_context, DEFAULT_LOG_PREVIEW_CHARS)))
        emit_log(env, "before=" .. join_candidate_preview(candidate_infos))
    end
    local order = rerank_candidates(env, context_snapshot, current_input, candidate_infos)
    if not order then
        for _, cand in ipairs(all_candidates) do yield(cand) end
        return
    end

    if fixed_first then
        yield(fixed_first)
    end

    local used = {}
    for _, index in ipairs(order) do
        local info = candidate_infos[index]
        local cand = info and info.candidate or nil
        if cand then
            used[index] = true
            yield(cand)
        end
    end
    local reordered_texts = {}
    for _, index in ipairs(order) do
        if candidate_infos[index] and candidate_infos[index].text then
            reordered_texts[#reordered_texts + 1] = candidate_infos[index].text
        end
    end
    remember_feedback_session(env, fixed_first and fixed_first.text or "", reordered_texts)
    if env.log_enabled then
        emit_log(env, "after=" .. join_candidate_preview(reordered_texts))
    end

    for i = 1, #candidate_infos do
        if not used[i] then
            yield(candidate_infos[i].candidate)
        end
    end

    for i = pool_limit + 1, #all_candidates do
        yield(all_candidates[i])
    end
end

function M.fini(env)
    if env.commit_notifier then
        env.commit_notifier:disconnect()
        env.commit_notifier = nil
    end
    env.last_signature = nil
    env.last_order = nil
    env.preference_history_snapshot = nil
    env.last_feedback_session = nil
    env.last_prewarm_signature = nil
    env.last_context_log_signature = nil
end

return M
