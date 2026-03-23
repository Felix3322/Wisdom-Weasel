---@diagnostic disable: undefined-global

local wanxiang = require("wanxiang/wanxiang")

local M = {}

local DEFAULT_API_URL = "http://127.0.0.1:8080/predict"
local DEFAULT_MAX_CANDIDATES = 5
local DEFAULT_MIN_SYLLABLE_COUNT = 5
local DEFAULT_CONTEXT_MAX_CHARS = 80
local DEFAULT_REQUEST_TIMEOUT_MS = 1200
local DEFAULT_INITIAL_QUALITY = 3.35
local DEFAULT_RETRY_COOLDOWN_MS = 3000
local DEFAULT_COMMENT = "〔旧译〕"
local DEFAULT_SHELL = "powershell.exe"

local function trim_spaces(text)
    text = text or ""
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function get_utf8_char(str, index)
    if not str or str == "" then return nil end
    local start_byte = utf8.offset(str, index)
    if not start_byte then return nil end
    local end_byte = utf8.offset(str, index + 1)
    return string.sub(str, start_byte, (end_byte and end_byte - 1) or nil)
end

local function esc_class(c)
    if not c or c == "" then return "" end
    return (c:gsub("([%%%^%]%-])", "%%%1"))
end

local function get_delimiters(ctx)
    local cfg = ctx.engine and ctx.engine.schema and ctx.engine.schema.config
    local delimiter = (cfg and cfg:get_string("speller/delimiter")) or " '"
    return get_utf8_char(delimiter, 1) or " ", get_utf8_char(delimiter, 2) or "'"
end

local function get_script_text_parts(ctx)
    local raw_in = ctx.input or ""
    local prop_key = ctx:get_property("sequence_preedit_key") or ""
    local prop_val = ctx:get_property("sequence_preedit_val") or ""
    local script_txt = ctx:get_script_text() or ""
    local text = (prop_key == raw_in and prop_val ~= "") and prop_val or script_txt
    if text == "" then return {} end

    local auto, manual = get_delimiters(ctx)
    local pat = "[^" .. esc_class(auto) .. esc_class(manual) .. "%s]+"
    local parts = {}
    for word in text:gmatch(pat) do
        parts[#parts + 1] = word
    end
    return parts
end

local function normalize_pinyin_parts(parts)
    local normalized = {}
    for _, part in ipairs(parts or {}) do
        local text = trim_spaces(part):gsub("[^A-Za-z]", ""):lower()
        if text ~= "" then
            normalized[#normalized + 1] = text
        end
    end
    return normalized
end

local function utf8_to_chars(text)
    local chars = {}
    if not text or text == "" then
        return chars
    end
    for _, code in utf8.codes(text) do
        chars[#chars + 1] = utf8.char(code)
    end
    return chars
end

local function utf8_tail(text, limit)
    if not text or text == "" or not limit or limit <= 0 then
        return text or ""
    end
    local chars = utf8_to_chars(text)
    if #chars <= limit then
        return text
    end
    return table.concat(chars, "", #chars - limit + 1, #chars)
end

local function get_recent_text_context(env)
    local records = {}
    local context = env.engine.context
    local history = context and context.commit_history or nil
    if not history or history:empty() then
        return ""
    end

    local raw_records = history:to_table()
    if type(raw_records) ~= "table" then
        return ""
    end

    for _, record in ipairs(raw_records) do
        local text = trim_spaces(record and record.text or "")
        if text ~= "" and text:sub(1, 1) ~= "/" then
            if #records == 0 or records[#records] ~= text then
                records[#records + 1] = text
            end
        end
    end

    if #records == 0 then
        return ""
    end

    local merged = table.concat(records, "")
    return utf8_tail(merged, env.context_max_chars)
end

local function contains_ascii_alpha(text)
    return text and text:find("[A-Za-z]") ~= nil or false
end

local function contains_cjk(text)
    if not text or text == "" then
        return false
    end
    for _, code in utf8.codes(text) do
        local ch = utf8.char(code)
        if wanxiang.IsChineseCharacter and wanxiang.IsChineseCharacter(ch) then
            return true
        end
    end
    return false
end

local function looks_like_candidate(text)
    text = trim_spaces(text)
    if text == "" then
        return false
    end
    if contains_ascii_alpha(text) then
        return false
    end
    return contains_cjk(text)
end

local function ps_single_quote(text)
    text = (text or ""):gsub("[\r\n]+", " ")
    return "'" .. text:gsub("'", "''") .. "'"
end

local function build_request_command(env, context_text, pinyin_text)
    local timeout_sec = math.max(1, math.ceil((env.request_timeout_ms or DEFAULT_REQUEST_TIMEOUT_MS) / 1000))
    local script = table.concat({
        "$ProgressPreference='SilentlyContinue'",
        "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8",
        "$payload=@{context=" .. ps_single_quote(context_text) .. ";pinyin=" .. ps_single_quote(pinyin_text) ..
            "} | ConvertTo-Json -Compress",
        "$resp=Invoke-RestMethod -Uri " .. ps_single_quote(env.api_url) ..
            " -Method Post -ContentType 'application/json; charset=utf-8' -Body $payload -TimeoutSec " ..
            tostring(timeout_sec),
        "if ($resp -and $resp.candidates) { foreach ($item in $resp.candidates) { if ($item -and $item.text) { $item.text } } }",
    }, "; ")

    return string.format('"%s" -NoLogo -NoProfile -NonInteractive -Command "%s"', env.shell, script)
end

local function fetch_candidates(env, context_text, pinyin_text)
    local command = build_request_command(env, context_text, pinyin_text)
    local pipe = io.popen(command, "r")
    if not pipe then
        return nil
    end

    local seen = {}
    local candidates = {}
    for line in pipe:lines() do
        local text = trim_spaces(line)
        if looks_like_candidate(text) and not seen[text] then
            seen[text] = true
            candidates[#candidates + 1] = text
            if #candidates >= env.max_candidates then
                break
            end
        end
    end
    pipe:close()
    return candidates
end

local function now_ms()
    if rime_api and rime_api.get_time_ms then
        return rime_api.get_time_ms()
    end
    return 0
end

function M.init(env)
    local config = env.engine.schema.config
    env.enabled = config:get_bool("legacy_http_translator/enabled")
    if env.enabled == nil then env.enabled = false end

    env.api_url = config:get_string("legacy_http_translator/api_url") or DEFAULT_API_URL
    env.max_candidates = config:get_int("legacy_http_translator/max_candidates") or DEFAULT_MAX_CANDIDATES
    env.min_syllable_count = config:get_int("legacy_http_translator/min_syllable_count") or DEFAULT_MIN_SYLLABLE_COUNT
    env.context_max_chars = config:get_int("legacy_http_translator/context_max_chars") or DEFAULT_CONTEXT_MAX_CHARS
    env.request_timeout_ms = config:get_int("legacy_http_translator/request_timeout_ms") or DEFAULT_REQUEST_TIMEOUT_MS
    env.retry_cooldown_ms = config:get_int("legacy_http_translator/retry_cooldown_ms") or DEFAULT_RETRY_COOLDOWN_MS
    env.comment = config:get_string("legacy_http_translator/comment") or DEFAULT_COMMENT
    env.shell = config:get_string("legacy_http_translator/shell") or DEFAULT_SHELL
    env.initial_quality = config:get_double("legacy_http_translator/initial_quality") or DEFAULT_INITIAL_QUALITY

    env.last_signature = nil
    env.last_candidates = nil
    env.retry_not_before_ms = 0
end

function M.func(input, seg, env)
    if not env.enabled then
        return
    end

    local context = env.engine.context
    if not context or wanxiang.is_function_mode_active(context) then
        return
    end
    if not seg or not seg:has_tag("abc") then
        return
    end
    if not env.api_url or env.api_url == "" then
        return
    end

    local script_parts = normalize_pinyin_parts(get_script_text_parts(context))
    if #script_parts < env.min_syllable_count then
        return
    end

    local pinyin_text = table.concat(script_parts, "")
    if pinyin_text == "" then
        return
    end

    local history_context = get_recent_text_context(env)
    local signature = history_context .. "\30" .. pinyin_text
    local current_ms = now_ms()

    local candidates = nil
    if env.last_signature == signature and type(env.last_candidates) == "table" then
        candidates = env.last_candidates
    elseif current_ms < (env.retry_not_before_ms or 0) then
        return
    else
        candidates = fetch_candidates(env, history_context, pinyin_text)
        if not candidates or #candidates == 0 then
            env.retry_not_before_ms = current_ms + env.retry_cooldown_ms
            return
        end
        env.last_signature = signature
        env.last_candidates = candidates
        env.retry_not_before_ms = 0
    end

    for _, text in ipairs(candidates) do
        local cand = Candidate("sentence", seg.start, seg._end, text, env.comment)
        cand.quality = env.initial_quality
        yield(cand)
    end
end

function M.fini(env)
    env.last_signature = nil
    env.last_candidates = nil
end

return M
