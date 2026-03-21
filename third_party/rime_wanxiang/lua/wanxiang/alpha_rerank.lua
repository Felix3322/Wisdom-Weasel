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

if alpha_core and log and log.warning then
    log.warning("[alpha_rerank] alpha_rerank_core module loaded")
end

local M = {}

local DEFAULT_CONTEXT_MAX_CHARS = 96
local DEFAULT_MAX_CANDIDATES = 8
local DEFAULT_RECENT_TAIL_CHARS = 24
local DEFAULT_ORDER_PRIOR_WEIGHT = 0.03

local function log_warn(message)
    if log and log.warning then
        log.warning(message)
    end
end

local function trim_spaces(text)
    if not text or text == "" then return "" end
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

local function clamp_tail_text(text, limit)
    if not text or text == "" or not limit or limit <= 0 then
        return text or ""
    end
    if utf8_len(text) <= limit then
        return text
    end
    return utf8_tail(text, limit)
end

local function is_strong_sentence_boundary(ch)
    return ch == "。" or ch == "！" or ch == "？" or ch == "!" or
        ch == "?" or ch == "；" or ch == ";" or ch == "\n" or ch == "\r"
end

local function get_commit_history_segments(env)
    local context = env.engine.context
    local history = context and context.commit_history or nil
    local segments = {}
    if not history or history:empty() then
        return segments
    end

    local records = history:to_table()
    if type(records) ~= "table" then
        return segments
    end

    for _, record in ipairs(records) do
        local text = record and record.text or ""
        text = trim_spaces(text)
        if text ~= "" and text:sub(1, 1) ~= "/" then
            if #segments == 0 or segments[#segments] ~= text then
                segments[#segments + 1] = text
            end
        end
    end
    return segments
end

local function get_recent_text_context(env)
    local segments = get_commit_history_segments(env)
    if #segments == 0 then
        return ""
    end

    local limit = env.context_max_chars > 0 and env.context_max_chars or DEFAULT_CONTEXT_MAX_CHARS
    local reversed_segments = {}
    local accumulated = 0
    for i = #segments, 1, -1 do
        local segment = segments[i]
        if segment and segment ~= "" then
            reversed_segments[#reversed_segments + 1] = segment
            accumulated = accumulated + utf8_len(segment)
            if accumulated >= limit then
                break
            end
        end
    end

    local text = ""
    for i = #reversed_segments, 1, -1 do
        text = text .. reversed_segments[i]
    end

    if utf8_len(text) > limit then
        text = utf8_tail(text, limit)
    end

    if not env.prefer_sentence_boundary or text == "" then
        return text
    end

    local chars = utf8_to_chars(text)
    local last_non_space = nil
    for i = #chars, 1, -1 do
        if not chars[i]:match("%s") then
            last_non_space = i
            break
        end
    end
    if not last_non_space then
        return text
    end

    local search_end = last_non_space
    if is_strong_sentence_boundary(chars[last_non_space]) then
        search_end = last_non_space - 1
    end

    local boundary_pos = nil
    for i = search_end, 1, -1 do
        if is_strong_sentence_boundary(chars[i]) then
            boundary_pos = i
            break
        end
    end

    if boundary_pos and boundary_pos < #chars then
        local sentence = table.concat(chars, "", boundary_pos + 1, #chars)
        sentence = trim_spaces(sentence)
        if sentence ~= "" then
            return sentence
        end
    end

    return text
end

local function build_rerank_context(context, recent_tail_chars)
    context = trim_spaces(context or "")
    if context == "" then
        return ""
    end

    context = clamp_tail_text(context, recent_tail_chars > 0 and recent_tail_chars * 2 or DEFAULT_CONTEXT_MAX_CHARS)

    local parts = { "用户输入记录：" .. context }
    local recent_tail = utf8_tail(context, recent_tail_chars)
    if recent_tail ~= "" and recent_tail ~= context then
        parts[#parts + 1] = "最近输入片段：" .. recent_tail
    end
    return clamp_tail_text(table.concat(parts, "\n"), DEFAULT_CONTEXT_MAX_CHARS)
end

local function make_signature(context, current_input, candidates)
    return table.concat({
        context or "",
        "\30",
        current_input or "",
        "\30",
        table.concat(candidates, "\31"),
    })
end

local function rerank_candidates(env, context, current_input, candidates)
    if not env.backend_ready or not env.core then
        return nil
    end

    local signature = make_signature(context, current_input, candidates)
    if signature == env.last_signature and env.last_order then
        return env.last_order
    end

    local rerank_context = build_rerank_context(context, env.recent_tail_chars)
    rerank_context = clamp_tail_text(rerank_context, env.context_max_chars)
    if rerank_context == "" then
        return nil
    end

    local scores, err = env.core.compute_similarities(rerank_context, candidates)
    if not scores then
        log_warn("[alpha_rerank] compute_similarities failed: " .. tostring(err or "unknown error"))
        return nil
    end

    for i = 1, #candidates do
        scores[i] = tonumber(scores[i]) or 0.0
    end

    local candidate_count = #scores
    if candidate_count > 1 then
        for i = 1, candidate_count do
            local order_prior = (candidate_count - i + 1) / candidate_count
            scores[i] = scores[i] + env.order_prior_weight * order_prior
        end
    end

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

    env.last_signature = signature
    env.last_order = order
    return order
end

function M.init(env)
    local config = env.engine.schema.config
    env.enabled = config:get_bool("alpha_rerank/enabled")
    if env.enabled == nil then env.enabled = false end

    env.max_candidates = config:get_int("alpha_rerank/max_candidates") or DEFAULT_MAX_CANDIDATES
    env.context_max_chars = config:get_int("alpha_rerank/context_max_chars") or DEFAULT_CONTEXT_MAX_CHARS
    env.recent_tail_chars = config:get_int("alpha_rerank/recent_tail_chars") or DEFAULT_RECENT_TAIL_CHARS
    env.order_prior_weight = config:get_double("alpha_rerank/order_prior_weight") or DEFAULT_ORDER_PRIOR_WEIGHT
    env.prefer_sentence_boundary = config:get_bool("alpha_rerank/prefer_sentence_boundary")
    if env.prefer_sentence_boundary == nil then env.prefer_sentence_boundary = true end

    env.tags = load_tags(config)
    env.core = alpha_core
    env.backend_ready = false
    env.last_signature = nil
    env.last_order = nil

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

    local fixed_first = all_candidates[1]
    local rerank_pool = {}
    local rerank_texts = {}
    local pool_limit = math.min(#all_candidates, env.max_candidates)
    for i = 2, pool_limit do
        local cand = all_candidates[i]
        local text = cand and cand.text or ""
        if text and text ~= "" then
            rerank_pool[#rerank_pool + 1] = cand
            rerank_texts[#rerank_texts + 1] = text
        end
    end

    if #rerank_pool < 1 then
        for _, cand in ipairs(all_candidates) do yield(cand) end
        return
    end

    local history_context = get_recent_text_context(env)
    local order = rerank_candidates(env, history_context, current_input, rerank_texts)
    if not order then
        for _, cand in ipairs(all_candidates) do yield(cand) end
        return
    end

    if fixed_first then
        yield(fixed_first)
    end

    local used = {}
    for _, index in ipairs(order) do
        local cand = rerank_pool[index]
        if cand then
            used[index] = true
            yield(cand)
        end
    end

    for i = 1, #rerank_pool do
        if not used[i] then
            yield(rerank_pool[i])
        end
    end

    for i = pool_limit + 1, #all_candidates do
        yield(all_candidates[i])
    end
end

function M.fini(env)
    env.last_signature = nil
    env.last_order = nil
end

return M
