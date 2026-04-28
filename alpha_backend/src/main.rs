use alpha_input::AlphaPredictive;
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::HashSet;
use std::env;
use std::sync::atomic::{AtomicU64, Ordering as AtomicOrdering};
use std::time::Instant;
use tiny_http::{Header, Method, Response, Server, StatusCode};

const RECENT_TAIL_CHARS: usize = 24;
const ORDER_PRIORITY_WEIGHT: f32 = 0.03;
static TRACE_SEQUENCE: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Deserialize)]
struct RerankRequest {
    context: String,
    current_input: Option<String>,
    candidates: Vec<String>,
    top_k: Option<usize>,
}

#[derive(Debug, Serialize)]
struct HealthResponse {
    status: &'static str,
    service: &'static str,
    config_path: String,
}

#[derive(Debug, Serialize)]
struct RerankResponse {
    ranked_indices: Vec<usize>,
    ranked_candidates: Vec<String>,
    scores: Vec<f32>,
    raw_ranked_indices: Vec<usize>,
    raw_ranked_candidates: Vec<String>,
    guarded_ranked_indices: Vec<usize>,
    guarded_ranked_candidates: Vec<String>,
    raw_top1: Option<String>,
    guarded_top1: Option<String>,
    score_status: &'static str,
    fallback_case_count: usize,
    low_context_confidence_case_count: usize,
    score_unavailable_case_count: usize,
    guard_triggered: bool,
    guard_reason: Option<String>,
    trace_id: String,
    latency_ms: f64,
    branches: Vec<String>,
}

#[derive(Debug, Serialize)]
struct ErrorResponse {
    error: String,
}

fn next_trace_id() -> String {
    let sequence = TRACE_SEQUENCE.fetch_add(1, AtomicOrdering::Relaxed);
    format!("已淘汰，请移步至ALPHA_LUA WEASEL_HTTP_RERANK-{sequence:08}")
}

fn main() {
    let (config_path, bind_addr) = match parse_args() {
        Ok(args) => args,
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(2);
        }
    };

    let predictor = match AlphaPredictive::new(&config_path) {
        Ok(predictor) => predictor,
        Err(err) => {
            eprintln!("failed to initialize alpha predictor: {err}");
            std::process::exit(1);
        }
    };

    let server = match Server::http(&bind_addr) {
        Ok(server) => server,
        Err(err) => {
            eprintln!("failed to bind {bind_addr}: {err}");
            std::process::exit(1);
        }
    };

    println!("alpha rerank server listening on {bind_addr}");

    for mut request in server.incoming_requests() {
        let method = request.method().clone();
        let path = request.url().split('?').next().unwrap_or("/");

        match (method, path) {
            (Method::Get, "/health") => {
                let body = HealthResponse {
                    status: "ok",
                    service: "alpha-rerank-server",
                    config_path: config_path.clone(),
                };
                let _ = request.respond(json_response(StatusCode(200), &body));
            }
            (Method::Post, "/v1/rerank") => {
                let response = handle_rerank(&mut request, &predictor);
                let _ = request.respond(response);
            }
            _ => {
                let body = ErrorResponse {
                    error: "not found".to_string(),
                };
                let _ = request.respond(json_response(StatusCode(404), &body));
            }
        }
    }
}

fn parse_args() -> Result<(String, String), String> {
    let mut config_path = String::from("config.toml");
    let mut bind_addr = String::from("127.0.0.1:8011");

    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--config" => {
                config_path = args
                    .next()
                    .ok_or_else(|| "--config requires a value".to_string())?;
            }
            "--bind" => {
                bind_addr = args
                    .next()
                    .ok_or_else(|| "--bind requires a value".to_string())?;
            }
            "--help" | "-h" => {
                return Err(
                    "usage: alpha-rerank-server --config <path> [--bind host:port]".to_string(),
                );
            }
            other => {
                return Err(format!("unknown argument: {other}"));
            }
        }
    }

    Ok((config_path, bind_addr))
}

fn handle_rerank(
    request: &mut tiny_http::Request,
    predictor: &AlphaPredictive,
) -> Response<std::io::Cursor<Vec<u8>>> {
    let mut body = String::new();
    if let Err(_err) = request.as_reader().read_to_string(&mut body) {
        return json_response(
            StatusCode(400),
            &ErrorResponse {
                error: "failed to read request body".to_string(),
            },
        );
    }

    let req: RerankRequest = match serde_json::from_str(&body) {
        Ok(req) => req,
        Err(_) => {
            return json_response(
                StatusCode(400),
                &ErrorResponse {
                    error: "invalid request JSON".to_string(),
                },
            );
        }
    };

    if req.candidates.is_empty() {
        return json_response(
            StatusCode(400),
            &ErrorResponse {
                error: "candidates must not be empty".to_string(),
            },
        );
    }

    let trace_id = next_trace_id();
    let top_k = req.top_k.unwrap_or(req.candidates.len()).max(1);
    let branch_contexts = build_branch_contexts(&req.context, req.current_input.as_deref());
    if branch_contexts.is_empty() {
        let ranked_candidates = req.candidates.into_iter().take(top_k).collect::<Vec<_>>();
        let scores = vec![0.0; ranked_candidates.len()];
        let ranked_indices = (0..ranked_candidates.len()).collect::<Vec<_>>();
        return json_response(
            StatusCode(200),
            &RerankResponse {
                ranked_indices: ranked_indices.clone(),
                ranked_candidates: ranked_candidates.clone(),
                scores,
                raw_ranked_indices: ranked_indices.clone(),
                raw_ranked_candidates: ranked_candidates.clone(),
                guarded_ranked_indices: ranked_indices,
                guarded_ranked_candidates: ranked_candidates.clone(),
                raw_top1: None,
                guarded_top1: ranked_candidates.first().cloned(),
                score_status: "skipped",
                fallback_case_count: 0,
                low_context_confidence_case_count: 1,
                score_unavailable_case_count: 1,
                guard_triggered: false,
                guard_reason: Some("empty_context".to_string()),
                trace_id,
                latency_ms: 0.0,
                branches: Vec::new(),
            },
        );
    }

    let started = Instant::now();
    let mut aggregated = req
        .candidates
        .iter()
        .enumerate()
        .map(|(idx, candidate)| (idx, candidate.clone(), 0.0f32))
        .collect::<Vec<_>>();

    for (branch_text, branch_weight) in &branch_contexts {
        let similarities = match predictor.compute_similarities(branch_text, &req.candidates) {
            Ok(similarities) => similarities,
            Err(_) => {
                return json_response(
                    StatusCode(500),
                    &ErrorResponse {
                        error: "rerank computation failed".to_string(),
                    },
                );
            }
        };
        for (idx, (_, score)) in similarities.into_iter().enumerate() {
            if let Some(item) = aggregated.get_mut(idx) {
                item.2 += branch_weight * score;
            }
        }
    }

    let candidate_count = aggregated.len();
    for (idx, _, score) in &mut aggregated {
        if candidate_count > 1 {
            let order_prior =
                (candidate_count.saturating_sub(*idx)) as f32 / candidate_count as f32;
            *score += ORDER_PRIORITY_WEIGHT * order_prior;
        }
    }

    let mut raw_ranked = aggregated;
    raw_ranked.sort_by(|lhs, rhs| {
        rhs.2
            .partial_cmp(&lhs.2)
            .unwrap_or(Ordering::Equal)
            .then_with(|| lhs.0.cmp(&rhs.0))
    });
    let raw_top1 = raw_ranked.first().map(|(_, candidate, _)| candidate.clone());
    let mut ranked = raw_ranked.clone();
    let guard_reason = apply_http_top1_guard(&mut ranked);
    let guard_triggered = guard_reason.is_some();
    let guarded_top1 = ranked.first().map(|(_, candidate, _)| candidate.clone());

    let raw_ranked_limited = raw_ranked.iter().take(top_k).cloned().collect::<Vec<_>>();
    ranked.truncate(top_k);

    let response = RerankResponse {
        ranked_indices: ranked.iter().map(|(idx, _, _)| *idx).collect(),
        ranked_candidates: ranked
            .iter()
            .map(|(_, candidate, _)| candidate.clone())
            .collect(),
        scores: ranked.iter().map(|(_, _, score)| *score).collect(),
        raw_ranked_indices: raw_ranked_limited.iter().map(|(idx, _, _)| *idx).collect(),
        raw_ranked_candidates: raw_ranked_limited
            .iter()
            .map(|(_, candidate, _)| candidate.clone())
            .collect(),
        guarded_ranked_indices: ranked.iter().map(|(idx, _, _)| *idx).collect(),
        guarded_ranked_candidates: ranked
            .iter()
            .map(|(_, candidate, _)| candidate.clone())
            .collect(),
        raw_top1,
        guarded_top1,
        score_status: "valid",
        fallback_case_count: 0,
        low_context_confidence_case_count: 0,
        score_unavailable_case_count: 0,
        guard_triggered,
        guard_reason,
        trace_id,
        latency_ms: started.elapsed().as_secs_f64() * 1000.0,
        branches: branch_contexts
            .iter()
            .map(|(text, weight)| format!("{weight:.2}: {text}"))
            .collect(),
    };

    json_response(StatusCode(200), &response)
}

fn build_branch_contexts(context: &str, _current_input: Option<&str>) -> Vec<(String, f32)> {
    let context = context.trim();
    if context.is_empty() {
        return Vec::new();
    }

    let mut branches = Vec::new();
    let mut seen = HashSet::new();

    let primary = format!("用户输入记录：{context}");
    if seen.insert(primary.clone()) {
        branches.push((primary, 0.20f32));
    }

    let raw = context.to_string();
    if seen.insert(raw.clone()) {
        branches.push((raw, 0.60f32));
    }

    let recent_tail = tail_chars(context, RECENT_TAIL_CHARS);
    if !recent_tail.is_empty() && recent_tail != context {
        let tail_branch = format!("最近输入片段：{recent_tail}");
        if seen.insert(tail_branch.clone()) {
            branches.push((tail_branch, 0.20f32));
        }
    }

    let weight_sum: f32 = branches.iter().map(|(_, weight)| *weight).sum();
    if weight_sum > 0.0 {
        for (_, weight) in &mut branches {
            *weight /= weight_sum;
        }
    }
    branches
}

fn char_len(text: &str) -> usize {
    text.chars().count()
}

fn is_modal_particle(text: &str) -> bool {
    matches!(text, "吧" | "呀" | "啊" | "呢" | "吗" | "嘛" | "啦" | "哇" | "呐" | "么" | "了")
}

fn is_function_word(text: &str) -> bool {
    matches!(
        text,
        "的" | "了" | "呢" | "吗" | "吧" | "啊" | "呀" | "就" | "也" | "都" | "还" | "再" | "又" | "才" | "并" | "且" | "而" | "但" | "却" | "或" | "及" | "与" | "和" | "把" | "被" | "给" | "向" | "从" | "对" | "在" | "以" | "因" | "为" | "于" | "将" | "让" | "使"
    )
}

fn promotion_cap(text: &str) -> Option<(f32, &'static str)> {
    let len = char_len(text);
    if is_modal_particle(text) {
        Some((0.02, "challenger_is_modal_particle"))
    } else if is_function_word(text) {
        Some((0.04, "challenger_is_function_word"))
    } else if len == 1 {
        Some((0.04, "challenger_is_single_char"))
    } else if len <= 2 {
        Some((0.06, "challenger_is_short_candidate"))
    } else {
        None
    }
}

fn apply_http_top1_guard(ranked: &mut [(usize, String, f32)]) -> Option<String> {
    if ranked.len() < 2 {
        return None;
    }
    let Some(original_position) = ranked.iter().position(|(idx, _, _)| *idx == 0) else {
        return None;
    };
    if original_position == 0 {
        return None;
    }

    let challenger_text = ranked[0].1.clone();
    let challenger_score = ranked[0].2;
    let original_text = ranked[original_position].1.clone();
    let original_score = ranked[original_position].2;
    let Some((cap, reason)) = promotion_cap(&challenger_text) else {
        return None;
    };
    let margin = challenger_score - original_score;
    if margin > cap {
        return None;
    }

    let original_item = ranked[original_position].clone();
    for index in (1..=original_position).rev() {
        ranked[index] = ranked[index - 1].clone();
    }
    ranked[0] = original_item;
    Some(format!(
        "{reason}; original_top1={}; challenger={}; raw_margin={margin:.4}; cap={cap:.4}",
        original_text, challenger_text
    ))
}

fn tail_chars(text: &str, keep: usize) -> String {
    let chars = text.chars().collect::<Vec<_>>();
    if chars.len() <= keep {
        return text.to_string();
    }
    chars[chars.len() - keep..].iter().collect()
}

fn json_response<T: Serialize>(
    status: StatusCode,
    payload: &T,
) -> Response<std::io::Cursor<Vec<u8>>> {
    let body = match serde_json::to_vec(payload) {
        Ok(v) => v,
        Err(err) => format!(r#"{{"error":"serialization failed: {err}"}}"#).into_bytes(),
    };
    let header = Header::from_bytes(
        b"Content-Type".as_slice(),
        b"application/json; charset=utf-8".as_slice(),
    )
    .expect("valid content-type header");
    Response::from_data(body)
        .with_status_code(status)
        .with_header(header)
}
