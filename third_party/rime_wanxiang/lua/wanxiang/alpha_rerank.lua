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
local DEFAULT_LOG_PREVIEW_CHARS = 160
local DEFAULT_INPUT_COVERAGE_MIN_LETTERS = 8

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

    local prefix = string.format("[alpha_rerank][%s] ", tostring(env.log_session_id or "session"))
    local line = prefix .. tostring(message or "")
    log_info(line)

    local log_path = tostring(env.log_file_path or ""):gsub("^%s+", ""):gsub("%s+$", "")
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
        scan_segments = {},
        scan_text = "",
        merged_tail = "",
        clauses = {},
        anchor_clause = "",
        recent_clause = "",
        recent_tail = "",
        clean_context = "",
    }

    if #deduped_segments == 0 then
        return snapshot
    end

    local scan_limit = math.max(
        limit * DEFAULT_CONTEXT_SCAN_MULTIPLIER,
        recent_tail_chars * 8,
        DEFAULT_CONTEXT_MAX_CHARS)
    local scan_segments, scan_text = select_recent_scan_segments(deduped_segments, scan_limit)
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
    snapshot.clean_context = compose_clean_context(snapshot.anchor_clause, snapshot.recent_clause, snapshot.merged_tail)
    if snapshot.clean_context == "" then
        snapshot.clean_context = snapshot.merged_tail
    end
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
    emit_log(env, string.format("%s scan_segments=%s", tostring(stage or "context"), format_text_array(snapshot.scan_segments or {})))
    emit_log(env, string.format("%s clauses=%s", tostring(stage or "context"), format_text_array(snapshot.clauses or {})))
    emit_log(env, string.format("%s anchor_clause=%s", tostring(stage or "context"), clamp_head_tail_text(snapshot.anchor_clause or "", DEFAULT_LOG_PREVIEW_CHARS)))
    emit_log(env, string.format("%s recent_clause=%s", tostring(stage or "context"), clamp_head_tail_text(snapshot.recent_clause or "", DEFAULT_LOG_PREVIEW_CHARS)))
    emit_log(env, string.format("%s recent_tail=%s", tostring(stage or "context"), clamp_head_tail_text(snapshot.recent_tail or "", DEFAULT_LOG_PREVIEW_CHARS)))
    emit_log(env, string.format("%s clean_context=%s", tostring(stage or "context"), clamp_head_tail_text(snapshot.clean_context or "", DEFAULT_LOG_PREVIEW_CHARS)))
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

local function append_context_line(parts, current_length, label, value, limit)
    value = trim_spaces(value or "")
    if value == "" then
        return current_length
    end

    local prefix = label or ""
    local separator_length = (#parts > 0) and 1 or 0
    local available = limit - current_length - separator_length - utf8_len(prefix)
    if available <= 0 then
        return current_length
    end

    local shortened_value = clamp_head_tail_text(value, available)
    if shortened_value == "" then
        return current_length
    end

    parts[#parts + 1] = prefix .. shortened_value
    return current_length + separator_length + utf8_len(prefix) + utf8_len(shortened_value)
end

local function build_rerank_context(snapshot, recent_tail_chars, context_max_chars)
    snapshot = snapshot or {}
    local limit = context_max_chars > 0 and context_max_chars or DEFAULT_CONTEXT_MAX_CHARS
    local clean_context = trim_spaces(snapshot.clean_context or "")
    if clean_context == "" then
        clean_context = trim_spaces(snapshot.merged_tail or "")
    end
    if clean_context == "" then
        return ""
    end

    local parts = {}
    local current_length = 0
    current_length = append_context_line(parts, current_length, "语义上下文：", clean_context, limit)

    local recent_clause = trim_spaces(snapshot.recent_clause or "")
    if recent_clause ~= "" and recent_clause ~= clean_context then
        current_length = append_context_line(parts, current_length, "最近片段：", recent_clause, limit)
    end

    local recent_tail = trim_spaces(snapshot.recent_tail or "")
    if recent_tail == "" then
        recent_tail = utf8_tail(clean_context, recent_tail_chars > 0 and recent_tail_chars or DEFAULT_RECENT_TAIL_CHARS)
    end
    if recent_tail ~= "" and recent_tail ~= clean_context and recent_tail ~= recent_clause then
        current_length = append_context_line(parts, current_length, "最新尾部：", recent_tail, limit)
    end

    if #parts == 0 then
        return clamp_head_tail_text(clean_context, limit)
    end
    return table.concat(parts, "\n")
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
        local candidate = tostring(candidates[index] or "")
        local score = tonumber(scores and scores[index] or 0.0) or 0.0
        preview[#preview + 1] = string.format("#%d:%s(%.4f)", rank, candidate, score)
    end
    return clamp_head_tail_text(table.concat(preview, " | "), DEFAULT_LOG_PREVIEW_CHARS)
end

local function format_coverage_candidates(candidates, ratios, bonuses)
    local preview = {}
    for i = 1, #candidates do
        preview[#preview + 1] = string.format(
            "%s(len=%d,cov=%.2f,bonus=%.4f)",
            tostring(candidates[i] or ""),
            utf8_len(candidates[i] or ""),
            tonumber(ratios and ratios[i] or 0.0) or 0.0,
            tonumber(bonuses and bonuses[i] or 0.0) or 0.0)
    end
    return clamp_head_tail_text(table.concat(preview, " | "), DEFAULT_LOG_PREVIEW_CHARS)
end

local function make_signature(rerank_context, candidates)
    return table.concat({
        rerank_context or "",
        "\30",
        table.concat(candidates, "\31"),
    })
end

local function maybe_prewarm_rerank_context(env, trigger)
    if not env or not env.backend_ready or not env.core or type(env.core.warm_query) ~= "function" then
        return
    end

    local context_snapshot = build_context_snapshot(env)
    emit_context_snapshot_logs(env, "prewarm", context_snapshot)
    local rerank_context = build_rerank_context(context_snapshot, env.recent_tail_chars, env.context_max_chars)
    if rerank_context == "" then
        return
    end

    local warm_signature = rerank_context
    if env.last_prewarm_signature == warm_signature then
        return
    end

    local started_at = rime_api and rime_api.get_time_ms and rime_api.get_time_ms() or nil
    local ok, err = env.core.warm_query(rerank_context)
    local finished_at = rime_api and rime_api.get_time_ms and rime_api.get_time_ms() or nil
    if not ok then
        if env.log_enabled then
            emit_log(env, "prewarm skipped: " .. tostring(err))
        end
        return
    end

    env.last_prewarm_signature = warm_signature
    if env.log_enabled then
        local elapsed_ms = (started_at and finished_at) and (finished_at - started_at) or -1
        emit_log(env,
            string.format(
                "prewarm done, trigger=%s, clean_context=%s, rerank_context=%s, context_chars=%d, elapsed_ms=%d",
                tostring(trigger or "unknown"),
                clamp_head_tail_text(context_snapshot.clean_context or "", DEFAULT_LOG_PREVIEW_CHARS),
                clamp_head_tail_text(rerank_context, DEFAULT_LOG_PREVIEW_CHARS),
                utf8_len(rerank_context),
                elapsed_ms))
    end
end

join_candidate_preview = function(candidates)
    local preview = {}
    for i = 1, #candidates do
        preview[#preview + 1] = tostring(candidates[i])
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

local function rerank_candidates(env, context_snapshot, current_input, candidates)
    if not env.backend_ready or not env.core then
        return nil
    end

    local rerank_context = build_rerank_context(context_snapshot, env.recent_tail_chars, env.context_max_chars)
    if rerank_context == "" then
        if env.log_enabled then
            emit_log(env, "skip rerank: empty history context")
        end
        return nil
    end

    local signature = make_signature(rerank_context, candidates)
    if signature == env.last_signature and env.last_order then
        if env.log_enabled then
            emit_log(env,
                string.format(
                    "cache hit, ime_input=%s, clean_context=%s, rerank_context=%s, before=%s",
                    tostring(current_input),
                    clamp_head_tail_text(context_snapshot and context_snapshot.clean_context or "", DEFAULT_LOG_PREVIEW_CHARS),
                    clamp_head_tail_text(rerank_context, DEFAULT_LOG_PREVIEW_CHARS),
                    join_candidate_preview(candidates)))
        end
        return env.last_order
    end

    local started_at = rime_api and rime_api.get_time_ms and rime_api.get_time_ms() or nil
    local scores, err = env.core.compute_similarities(rerank_context, candidates)
    if not scores then
        log_warn("[alpha_rerank] compute_similarities failed: " .. tostring(err or "unknown error"))
        return nil
    end
    local finished_at = rime_api and rime_api.get_time_ms and rime_api.get_time_ms() or nil

    for i = 1, #candidates do
        scores[i] = tonumber(scores[i]) or 0.0
    end

    local candidate_count = #scores
    local expected_candidate_chars = estimate_expected_candidate_chars(current_input)
    local coverage_ratios = {}
    local coverage_bonuses = {}
    if candidate_count > 1 then
        for i = 1, candidate_count do
            local order_prior = (candidate_count - i + 1) / candidate_count
            scores[i] = scores[i] + env.order_prior_weight * order_prior
        end
    end
    if expected_candidate_chars > 0 and env.input_coverage_weight > 0 then
        for i = 1, candidate_count do
            local coverage_bonus, coverage_ratio = compute_input_coverage_bonus(
                env,
                current_input,
                candidates[i],
                expected_candidate_chars)
            coverage_ratios[i] = coverage_ratio
            coverage_bonuses[i] = coverage_bonus
            scores[i] = scores[i] + coverage_bonus
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
    local elapsed_ms = (started_at and finished_at) and (finished_at - started_at) or -1
    if env.log_enabled then
        emit_log(env,
            string.format(
                "rerank done, ime_input=%s, clean_context=%s, rerank_context=%s, context_chars=%d, pool=%d, expected_candidate_chars=%d, elapsed_ms=%d",
                tostring(current_input),
                clamp_head_tail_text(context_snapshot and context_snapshot.clean_context or "", DEFAULT_LOG_PREVIEW_CHARS),
                clamp_head_tail_text(rerank_context, DEFAULT_LOG_PREVIEW_CHARS),
                utf8_len(rerank_context),
                #candidates,
                expected_candidate_chars,
                elapsed_ms))
        emit_log(env, "scores=" .. format_scored_candidates(candidates, scores, order))
        if expected_candidate_chars > 0 then
            emit_log(env, "coverage=" .. format_coverage_candidates(candidates, coverage_ratios, coverage_bonuses))
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
    env.preserve_first_min_chars = config:get_int("alpha_rerank/preserve_first_min_chars") or
        DEFAULT_PRESERVE_FIRST_MIN_CHARS
    env.prefer_sentence_boundary = config:get_bool("alpha_rerank/prefer_sentence_boundary")
    if env.prefer_sentence_boundary == nil then env.prefer_sentence_boundary = true end
    env.log_enabled = config:get_bool("alpha_rerank/log_enabled")
    if env.log_enabled == nil then env.log_enabled = false end
    env.log_file_path = resolve_path(config:get_string("alpha_rerank/log_path") or "")
    if env.log_file_path == "" and rime_api and rime_api.get_user_data_dir then
        local user_data_dir = trim_spaces(rime_api.get_user_data_dir() or "")
        if user_data_dir ~= "" then
            env.log_file_path = user_data_dir .. "/alpha_rerank.log"
        end
    end
    env.log_session_id = os and os.date and os.date("%Y%m%d-%H%M%S") or tostring(math.floor((rime_api and rime_api.get_time_ms and rime_api.get_time_ms() or 0)))
    env.log_file_failed = false

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
        emit_log(env,
            string.format(
                "settings: max_candidates=%d, max_negative_candidates=%d, context_max_chars=%d, recent_tail_chars=%d, order_prior_weight=%.3f, input_coverage_weight=%.3f, preserve_first_min_chars=%d",
                env.max_candidates,
                env.max_negative_candidates,
                env.context_max_chars,
                env.recent_tail_chars,
                env.order_prior_weight,
                env.input_coverage_weight,
                env.preserve_first_min_chars))
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
    local rerank_texts = {}
    local pool_limit = math.min(#all_candidates, env.max_candidates)
    local pool_start = preserve_first and 2 or 1
    for i = pool_start, pool_limit do
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
                #rerank_pool,
                clamp_head_tail_text(rerank_context, DEFAULT_LOG_PREVIEW_CHARS)))
        emit_log(env, "before=" .. join_candidate_preview(rerank_texts))
    end
    local order = rerank_candidates(env, context_snapshot, current_input, rerank_texts)
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
    local reordered_texts = {}
    for _, index in ipairs(order) do
        if rerank_texts[index] then
            reordered_texts[#reordered_texts + 1] = rerank_texts[index]
        end
    end
    remember_feedback_session(env, fixed_first and fixed_first.text or "", reordered_texts)
    if env.log_enabled then
        emit_log(env, "after=" .. join_candidate_preview(reordered_texts))
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
