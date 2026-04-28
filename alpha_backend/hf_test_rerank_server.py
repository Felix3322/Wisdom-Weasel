import os
import time
import itertools
from typing import List, Optional

import torch
import torch.nn.functional as F
import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from transformers import AutoModel, AutoTokenizer


MODEL_ID = os.environ.get("ALPHA_TEST_MODEL", "Qwen/Qwen3-0.6B")
MAX_INPUT_LENGTH = int(os.environ.get("ALPHA_TEST_MAX_INPUT_LENGTH", "512"))
HOST = os.environ.get("ALPHA_TEST_HOST", "127.0.0.1")
PORT = int(os.environ.get("ALPHA_TEST_PORT", "8011"))

DEVICE = "cuda" if torch.cuda.is_available() else "cpu"
DTYPE = torch.float16 if DEVICE == "cuda" else torch.float32

app = FastAPI(
    title="Alpha HF Test Rerank Server",
    description="用于快速验证 alpha 风格重排效果的 HF 直连测试服务",
    version="0.1.0",
)

tokenizer = None
model = None
embedding_weight = None
trace_counter = itertools.count(1)


class RerankRequest(BaseModel):
    context: str = Field(default="")
    current_input: Optional[str] = Field(default=None)
    candidates: List[str] = Field(default_factory=list)
    top_k: Optional[int] = Field(default=None)


class RerankResponse(BaseModel):
    ranked_indices: List[int]
    ranked_candidates: List[str]
    scores: List[float]
    raw_ranked_indices: List[int]
    raw_ranked_candidates: List[str]
    guarded_ranked_indices: List[int]
    guarded_ranked_candidates: List[str]
    raw_top1: Optional[str] = None
    guarded_top1: Optional[str] = None
    score_status: str = "valid"
    fallback_case_count: int = 0
    low_context_confidence_case_count: int = 0
    score_unavailable_case_count: int = 0
    guard_triggered: bool = False
    guard_reason: Optional[str] = None
    trace_id: str
    latency_ms: float


def _load_model():
    global tokenizer, model, embedding_weight
    if tokenizer is not None and model is not None and embedding_weight is not None:
        return

    print(f"[alpha-hf-test] loading model: {MODEL_ID}", flush=True)
    print(f"[alpha-hf-test] device={DEVICE}, dtype={DTYPE}, max_input_length={MAX_INPUT_LENGTH}", flush=True)
    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID, trust_remote_code=True)
    model = AutoModel.from_pretrained(
        MODEL_ID,
        trust_remote_code=True,
        dtype=DTYPE,
        attn_implementation="eager",
        low_cpu_mem_usage=True,
    )
    model.to(DEVICE)
    model.eval()
    embedding_weight = model.get_input_embeddings().weight
    print("[alpha-hf-test] model loaded", flush=True)


def _get_predict_vector(context: str) -> torch.Tensor:
    inputs = tokenizer(
        context,
        return_tensors="pt",
        truncation=True,
        max_length=MAX_INPUT_LENGTH,
    )
    inputs = {k: v.to(DEVICE) for k, v in inputs.items()}

    with torch.no_grad():
        outputs = model(**inputs, use_cache=False, return_dict=True)

    seq_len = int(inputs["attention_mask"][0].sum().item())
    if seq_len <= 0:
        raise ValueError("empty sequence after tokenization")

    return outputs.last_hidden_state[0, seq_len - 1].float()


def _build_reference_context(context: str, current_input: Optional[str]) -> str:
    context = (context or "").strip()
    current_input = (current_input or "").strip()
    if not context:
        return ""

    lines = [f"用户输入记录：{context}"]
    if current_input:
        lines.append(f"当前拼音：{current_input}")
    return "\n".join(lines)


def _get_candidate_embedding(candidate: str) -> torch.Tensor:
    token_ids = tokenizer.encode(candidate, add_special_tokens=True)
    if not token_ids:
        raise ValueError(f"candidate has no token ids: {candidate}")
    token_tensor = torch.tensor(token_ids, dtype=torch.long, device=embedding_weight.device)
    return embedding_weight[token_tensor].float().mean(dim=0)


def _next_trace_id() -> str:
    return f"已淘汰，请移步至ALPHA_LUA WEASEL_HTTP_RERANK-HFTEST-{next(trace_counter):08d}"


def _char_len(text: str) -> int:
    return len(text or "")


def _promotion_cap(text: str):
    modal = {"吧", "呀", "啊", "呢", "吗", "嘛", "啦", "哇", "呐", "么", "了"}
    function_words = modal | {
        "的", "就", "也", "都", "还", "再", "又", "才", "并", "且", "而", "但", "却",
        "或", "及", "与", "和", "把", "被", "给", "向", "从", "对", "在", "以", "因",
        "为", "于", "将", "让", "使",
    }
    length = _char_len(text)
    if text in modal:
        return 0.02, "challenger_is_modal_particle"
    if text in function_words:
        return 0.04, "challenger_is_function_word"
    if length == 1:
        return 0.04, "challenger_is_single_char"
    if length <= 2:
        return 0.06, "challenger_is_short_candidate"
    return None


def _apply_top1_guard(ranked):
    original_position = next((i for i, item in enumerate(ranked) if item[0] == 0), None)
    if original_position in (None, 0):
        return ranked, None
    challenger = ranked[0]
    original = ranked[original_position]
    cap = _promotion_cap(challenger[1])
    if cap is None:
        return ranked, None
    max_margin, reason = cap
    margin = challenger[2] - original[2]
    if margin > max_margin:
        return ranked, None
    guarded = [original] + [item for item in ranked if item[0] != original[0]]
    return guarded, f"{reason}; original_top1={original[1]}; challenger={challenger[1]}; raw_margin={margin:.4f}; cap={max_margin:.4f}"


@app.on_event("startup")
def startup_event():
    _load_model()


@app.get("/health")
def health():
    return {
        "status": "ok",
        "model_id": MODEL_ID,
        "device": DEVICE,
    }


@app.post("/v1/rerank", response_model=RerankResponse)
def rerank(req: RerankRequest):
    if not req.candidates:
        raise HTTPException(status_code=400, detail="candidates must not be empty")

    top_k = max(1, req.top_k or len(req.candidates))
    trace_id = _next_trace_id()
    context = _build_reference_context(req.context, req.current_input)

    if not context:
        ranked_candidates = req.candidates[:top_k]
        ranked_indices = list(range(len(ranked_candidates)))
        return RerankResponse(
            ranked_indices=ranked_indices,
            ranked_candidates=ranked_candidates,
            scores=[0.0 for _ in ranked_candidates],
            raw_ranked_indices=ranked_indices,
            raw_ranked_candidates=ranked_candidates,
            guarded_ranked_indices=ranked_indices,
            guarded_ranked_candidates=ranked_candidates,
            guarded_top1=ranked_candidates[0] if ranked_candidates else None,
            score_status="skipped",
            low_context_confidence_case_count=1,
            score_unavailable_case_count=1,
            guard_reason="empty_context",
            trace_id=trace_id,
            latency_ms=0.0,
        )

    started = time.perf_counter()
    with torch.no_grad():
        target = _get_predict_vector(context)
        ranked = []
        for index, candidate in enumerate(req.candidates):
            candidate_vector = _get_candidate_embedding(candidate)
            score = float(
                F.cosine_similarity(target.unsqueeze(0), candidate_vector.unsqueeze(0)).item()
            )
            ranked.append((index, candidate, score))

    ranked.sort(key=lambda item: (-item[2], item[0]))
    raw_ranked = list(ranked)
    guarded_ranked, guard_reason = _apply_top1_guard(ranked)
    ranked = guarded_ranked[:top_k]
    raw_ranked_limited = raw_ranked[:top_k]

    return RerankResponse(
        ranked_indices=[index for index, _, _ in ranked],
        ranked_candidates=[candidate for _, candidate, _ in ranked],
        scores=[score for _, _, score in ranked],
        raw_ranked_indices=[index for index, _, _ in raw_ranked_limited],
        raw_ranked_candidates=[candidate for _, candidate, _ in raw_ranked_limited],
        guarded_ranked_indices=[index for index, _, _ in ranked],
        guarded_ranked_candidates=[candidate for _, candidate, _ in ranked],
        raw_top1=raw_ranked[0][1] if raw_ranked else None,
        guarded_top1=ranked[0][1] if ranked else None,
        score_status="valid",
        guard_triggered=guard_reason is not None,
        guard_reason=guard_reason,
        trace_id=trace_id,
        latency_ms=(time.perf_counter() - started) * 1000.0,
    )


if __name__ == "__main__":
    _load_model()
    uvicorn.run(app, host=HOST, port=PORT)
