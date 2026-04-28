# -*- coding: utf-8 -*-
import json
import os
import sys
import warnings
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(line_buffering=True, write_through=True)
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(line_buffering=True, write_through=True)

print("Starting Pinyin Transformer demo...", flush=True)

FORCE_CPU = os.getenv("IME_DEMO_FORCE_CPU", "").strip().lower() in ("1", "true", "yes", "on")
if FORCE_CPU:
    os.environ["CUDA_VISIBLE_DEVICES"] = ""
    print("CPU-only mode enabled (IME_DEMO_FORCE_CPU=1).", flush=True)

print("Importing torch...", flush=True)

import torch
import torch.nn.functional as F

print(f"Torch imported. version={torch.__version__}", flush=True)

# Add parent directory to sys.path to import modules
parent_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if parent_dir not in sys.path:
    sys.path.append(parent_dir)

from IMETokenizer import IMETokenizerGB2312, PinyinTokenizer

warnings.filterwarnings(
    "ignore",
    message="enable_nested_tensor is True, but self.use_nested_tensor is False because encoder_layer.norm_first was True",
)

from pinyinModel import PinyinTransformer

# 直接写死推理配置，避免导入 train_easy 时顺带依赖 pypinyin
DMODEL = 512
NHEAD = 8
NUM_LAYERS = 6

HOST = os.getenv("IME_DEMO_HOST", "127.0.0.1")
PORT = int(os.getenv("IME_DEMO_PORT", "8080"))
MODEL_SAVE_PATH = os.path.join(parent_dir, "best_model_stage_2_large.pth")
INDEX_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html")

print("Selecting device...", flush=True)
device = torch.device("cpu" if FORCE_CPU else ("cuda" if torch.cuda.is_available() else "cpu"))
print(f"Using device: {device}", flush=True)
char_tokenizer = IMETokenizerGB2312()
py_tokenizer = PinyinTokenizer()

print("Building model...", flush=True)
model = PinyinTransformer(
    char_vocab_size=char_tokenizer.vocab_size,
    pinyin_vocab_size=py_tokenizer.vocab_size,
    d_model=DMODEL,
    nhead=NHEAD,
    num_layers=NUM_LAYERS,
).to(device)
print("Model structure initialized.", flush=True)


def load_model():
    print("Loading model weights... this can take a little while.", flush=True)
    if not os.path.exists(MODEL_SAVE_PATH):
        raise FileNotFoundError(f"Model not found at {MODEL_SAVE_PATH}")

    state_dict = torch.load(MODEL_SAVE_PATH, map_location=device)
    model.load_state_dict(state_dict)
    model.eval()
    print(f"Model loaded successfully from {MODEL_SAVE_PATH}.", flush=True)


def get_beam_candidates(model, char_tok, py_tok, context_text, pinyin_text, beam_width=5, max_len=20, device='cpu'):
    model.eval()

    if len(context_text) > 32:
        context_text = context_text[-32:]

    py_enc = py_tok(pinyin_text, return_tensors="pt")
    src = py_enc['input_ids'].to(device)
    src_key_padding_mask = (src == py_tok.pad_token_id)

    with torch.no_grad():
        src_emb = model.pinyin_embedding(src) * (model.d_model ** 0.5)
        src_emb = model.pos_encoder(src_emb)
        memory = model.transformer_encoder(src_emb, src_key_padding_mask=src_key_padding_mask)

    start_ids = [char_tok.cls_token_id] + [char_tok.v2i.get(c, char_tok.unk_token_id) for c in context_text]
    beams = [(0.0, start_ids)]
    context_length = len(start_ids)

    with torch.no_grad():
        for _ in range(max_len):
            all_candidates = []
            for score, seq in beams:
                if seq[-1] == char_tok.sep_token_id:
                    all_candidates.append((score, seq))
                    continue

                tgt_ids = torch.tensor([seq], dtype=torch.long).to(device)
                tgt_key_padding_mask = (tgt_ids == char_tok.pad_token_id)

                tgt_emb = model.char_embedding(tgt_ids) * (model.d_model ** 0.5)
                tgt_emb = model.pos_encoder(tgt_emb)
                tgt_mask = model.generate_square_subsequent_mask(tgt_ids.size(1), device)

                out = model.transformer_decoder(
                    tgt=tgt_emb,
                    memory=memory,
                    tgt_mask=tgt_mask,
                    tgt_key_padding_mask=tgt_key_padding_mask,
                    memory_key_padding_mask=src_key_padding_mask,
                )

                logits = model.fc_out(out)
                next_token_logits = logits[:, -1, :]
                log_probs = F.log_softmax(next_token_logits, dim=-1).squeeze(0)
                topk_log_probs, topk_indices = torch.topk(log_probs, beam_width)

                for i in range(beam_width):
                    next_token = topk_indices[i].item()
                    step_prob = topk_log_probs[i].item()
                    new_score = score + step_prob
                    new_seq = seq + [next_token]
                    all_candidates.append((new_score, new_seq))

            beams = sorted(all_candidates, key=lambda tup: tup[0], reverse=True)[:beam_width]

            if all(seq[-1] == char_tok.sep_token_id for _, seq in beams):
                break

    scores_tensor = torch.tensor([b[0] for b in beams])
    probs = F.softmax(scores_tensor, dim=0).tolist()
    results = []

    for idx, (_, seq) in enumerate(beams):
        gen_seq = seq[context_length:]
        if gen_seq and gen_seq[-1] == char_tok.sep_token_id:
            gen_seq = gen_seq[:-1]

        decoded_text = char_tok.decode(gen_seq) or " "
        results.append({
            "text": decoded_text,
            "probability": round(probs[idx], 4),
        })

    return results


class DemoRequestHandler(BaseHTTPRequestHandler):
    server_version = "PinyinTransformerDemo/1.0"

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        super().end_headers()

    def log_message(self, fmt, *args):
        print(f"[{self.log_date_time_string()}] {self.address_string()} - {fmt % args}")

    def _send_json(self, payload, status=HTTPStatus.OK):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, html_text, status=HTTPStatus.OK):
        body = html_text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(HTTPStatus.NO_CONTENT)
        self.end_headers()

    def do_GET(self):
        path = urlparse(self.path).path
        if path not in ("/", "/index.html"):
            self._send_json({"error": "Not found"}, status=HTTPStatus.NOT_FOUND)
            return

        with open(INDEX_PATH, "r", encoding="utf-8") as f:
            self._send_html(f.read())

    def do_POST(self):
        path = urlparse(self.path).path
        if path != "/predict":
            self._send_json({"error": "Not found"}, status=HTTPStatus.NOT_FOUND)
            return

        try:
            content_length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(content_length) if content_length > 0 else b"{}"
            payload = json.loads(body.decode("utf-8"))
            context = payload.get("context", "")
            pinyin = payload.get("pinyin", "")

            if not isinstance(context, str) or not isinstance(pinyin, str):
                raise ValueError("context 和 pinyin 必须是字符串")

            candidates = get_beam_candidates(
                model,
                char_tokenizer,
                py_tokenizer,
                context,
                pinyin,
                beam_width=5,
                device=device,
            )
            self._send_json({"candidates": candidates})
        except Exception as e:
            self._send_json({"error": str(e)}, status=HTTPStatus.INTERNAL_SERVER_ERROR)


class ReusableThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True


def run_server():
    load_model()
    server = ReusableThreadingHTTPServer((HOST, PORT), DemoRequestHandler)
    print(f"Demo is running at http://{HOST}:{PORT}", flush=True)
    print("Press Ctrl+C to stop.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped.")
    finally:
        server.server_close()


if __name__ == "__main__":
    run_server()
