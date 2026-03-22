use alpha_input::AlphaPredictive;
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::HashSet;
use std::env;
use std::time::Instant;
use tiny_http::{Header, Method, Response, Server, StatusCode};

const RECENT_TAIL_CHARS: usize = 24;

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
    latency_ms: f64,
    branches: Vec<String>,
}

#[derive(Debug, Serialize)]
struct ErrorResponse {
    error: String,
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
    if let Err(err) = request.as_reader().read_to_string(&mut body) {
        return json_response(
            StatusCode(400),
            &ErrorResponse {
                error: format!("failed to read request body: {err}"),
            },
        );
    }

    let req: RerankRequest = match serde_json::from_str(&body) {
        Ok(req) => req,
        Err(err) => {
            return json_response(
                StatusCode(400),
                &ErrorResponse {
                    error: format!("invalid json: {err}"),
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

    let top_k = req.top_k.unwrap_or(req.candidates.len()).max(1);
    let branch_contexts = build_branch_contexts(&req.context, req.current_input.as_deref());
    if branch_contexts.is_empty() {
        let ranked_candidates = req.candidates.into_iter().take(top_k).collect::<Vec<_>>();
        let scores = vec![0.0; ranked_candidates.len()];
        return json_response(
            StatusCode(200),
            &RerankResponse {
                ranked_indices: (0..ranked_candidates.len()).collect(),
                ranked_candidates,
                scores,
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
            Err(err) => {
                return json_response(
                    StatusCode(500),
                    &ErrorResponse {
                        error: format!("rerank failed: {err}"),
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
            *score += 0.03 * order_prior;
        }
    }

    let mut ranked = aggregated;
    ranked.sort_by(|lhs, rhs| {
        rhs.2
            .partial_cmp(&lhs.2)
            .unwrap_or(Ordering::Equal)
            .then_with(|| lhs.0.cmp(&rhs.0))
    });
    ranked.truncate(top_k);

    let response = RerankResponse {
        ranked_indices: ranked.iter().map(|(idx, _, _)| *idx).collect(),
        ranked_candidates: ranked
            .iter()
            .map(|(_, candidate, _)| candidate.clone())
            .collect(),
        scores: ranked.iter().map(|(_, _, score)| *score).collect(),
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
    let body = serde_json::to_vec(payload)
        .unwrap_or_else(|err| format!(r#"{{"error":"serialization failed: {err}"}}"#).into_bytes());
    let header = Header::from_bytes(
        b"Content-Type".as_slice(),
        b"application/json; charset=utf-8".as_slice(),
    )
    .expect("valid content-type header");
    Response::from_data(body)
        .with_status_code(status)
        .with_header(header)
}
