import os
import sys
from pathlib import Path

try:
    from transformers import AutoTokenizer, AutoModelForCausalLM
    from huggingface_hub import snapshot_download
except ImportError:
    print("请先安装必要的依赖包:")
    print("pip install transformers torch huggingface_hub")
    sys.exit(1)

def download_qwen3_model():
    """
    下载模型
    """
    # 设置模型名称
    model_name = "uer/gpt2-distil-chinese-cluecorpussmall"
    
    # 设置保存路径(默认在上一级目录)
    current_dir = Path(__file__).parent
    save_dir = current_dir.parent / "gpt2"
    
    print(f"开始下载模型: {model_name}")
    print(f"保存路径: {save_dir.absolute()}")
    
    # 创建保存目录
    save_dir.mkdir(parents=True, exist_ok=True)
    
    try:
        # 下载模型和tokenizer
        print("正在下载模型文件...")
        snapshot_download(
            repo_id=model_name,
            local_dir=str(save_dir),
            local_dir_use_symlinks=False,
            resume_download=True
        )
        
        print(f"模型下载完成！保存在: {save_dir.absolute()}")
        
        # 验证下载是否成功
        print("验证模型文件...")
        tokenizer = AutoTokenizer.from_pretrained(str(save_dir))
        model = AutoModelForCausalLM.from_pretrained(str(save_dir))
        
        print("模型验证成功！")
        print(f"模型参数量: {model.num_parameters():,}")
        
    except Exception as e:
        print(f"下载过程中出现错误: {e}")
        sys.exit(1)

if __name__ == "__main__":
    download_qwen3_model()
