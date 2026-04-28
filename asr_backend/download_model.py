from pathlib import Path

from huggingface_hub import snapshot_download


ROOT = Path(__file__).resolve().parent
MODEL_DIR = ROOT / "models" / "paraformer-zh-streaming"
MODEL_ID = "funasr/paraformer-zh-streaming"


def main():
    MODEL_DIR.parent.mkdir(parents=True, exist_ok=True)
    snapshot_download(
        repo_id=MODEL_ID,
        local_dir=str(MODEL_DIR),
    )
    print(f"downloaded: {MODEL_DIR}")


if __name__ == "__main__":
    main()
