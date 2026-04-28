import os
import threading
from pathlib import Path
from tempfile import NamedTemporaryFile

import numpy as np
import soundfile as sf
from fastapi import FastAPI, File, HTTPException, UploadFile
from funasr import AutoModel


ROOT = Path(__file__).resolve().parents[1]
MODEL_DIR = Path(
    os.getenv(
        "WW_ASR_MODEL_DIR",
        str(ROOT / "models" / "paraformer-zh-streaming"),
    )
)
MODEL_ID = os.getenv("WW_ASR_MODEL_ID", "funasr/paraformer-zh-streaming")
TARGET_SAMPLE_RATE = 16000
CHUNK_SIZE = [0, 10, 5]
CHUNK_STRIDE = CHUNK_SIZE[1] * 960
ENCODER_CHUNK_LOOK_BACK = 4
DECODER_CHUNK_LOOK_BACK = 1

app = FastAPI(title="Wisdom-Weasel Streaming ASR", version="0.1.0")
_model = None
_model_lock = threading.Lock()


def _load_model():
    global _model
    if _model is not None:
        return _model
    with _model_lock:
        if _model is not None:
            return _model
        model_source = str(MODEL_DIR) if MODEL_DIR.exists() else MODEL_ID
        _model = AutoModel(model=model_source, disable_update=True)
        return _model


def _resample_linear(audio: np.ndarray, source_sr: int, target_sr: int) -> np.ndarray:
    if source_sr == target_sr:
        return audio.astype(np.float32, copy=False)
    if audio.size == 0:
        return audio.astype(np.float32)

    target_len = max(1, int(round(audio.shape[0] * target_sr / source_sr)))
    source_idx = np.arange(audio.shape[0], dtype=np.float32)
    target_idx = np.linspace(0, audio.shape[0] - 1, target_len, dtype=np.float32)
    return np.interp(target_idx, source_idx, audio).astype(np.float32)


def _load_audio(audio_path: Path) -> np.ndarray:
    audio, sample_rate = sf.read(str(audio_path), dtype="float32", always_2d=False)
    if audio.ndim > 1:
        audio = np.mean(audio, axis=1)
    audio = np.asarray(audio, dtype=np.float32)
    return _resample_linear(audio, sample_rate, TARGET_SAMPLE_RATE)


def _extract_text(result) -> str:
    if isinstance(result, list) and result:
        item = result[0]
        if isinstance(item, dict):
            return (item.get("text") or "").strip()
        if isinstance(item, str):
            return item.strip()
    if isinstance(result, dict):
        return (result.get("text") or "").strip()
    if isinstance(result, str):
        return result.strip()
    return ""


def _stream_transcribe(audio: np.ndarray) -> str:
    model = _load_model()
    cache = {}
    pieces: list[str] = []

    for start in range(0, len(audio), CHUNK_STRIDE):
        end = min(start + CHUNK_STRIDE, len(audio))
        is_final = end >= len(audio)
        chunk = audio[start:end]
        result = model.generate(
            input=chunk,
            cache=cache,
            is_final=is_final,
            chunk_size=CHUNK_SIZE,
            encoder_chunk_look_back=ENCODER_CHUNK_LOOK_BACK,
            decoder_chunk_look_back=DECODER_CHUNK_LOOK_BACK,
        )
        text = _extract_text(result)
        if text:
            pieces.append(text)

    return "".join(pieces).strip()


@app.get("/health")
def health():
    return {
        "ok": True,
        "model_dir": str(MODEL_DIR),
        "model_exists": MODEL_DIR.exists(),
        "model_id": MODEL_ID,
    }


@app.post("/v1/transcribe")
async def transcribe(file: UploadFile = File(...)):
    suffix = Path(file.filename or "audio.wav").suffix or ".wav"
    try:
        with NamedTemporaryFile(delete=False, suffix=suffix) as temp_file:
            temp_path = Path(temp_file.name)
            temp_file.write(await file.read())

        audio = _load_audio(temp_path)
        if audio.size == 0:
            raise HTTPException(status_code=400, detail="audio is empty")

        text = _stream_transcribe(audio)
        return {"text": text}
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    finally:
        try:
            if "temp_path" in locals() and temp_path.exists():
                temp_path.unlink()
        except OSError:
            pass
