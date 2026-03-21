# Alpha 实时重排后端

这个目录提供 Wisdom-Weasel 有拼音场景使用的 **alpha 风格实时重排服务**。

## 架构

- 核心算法：直接复用 `../third_party/alpha-input`
- 部署形态：本地 HTTP 服务
- 默认接口：`POST http://127.0.0.1:8011/v1/rerank`
- 排序策略：多分支上下文加权融合
  - `用户输入记录：...`
  - 原始最近上下文
  - 最近输入片段

## 请求格式

```json
{
  "context": "今天下午要开",
  "current_input": "huiyi",
  "candidates": ["会议", "回忆", "会意", "汇译"],
  "top_k": 4
}
```

返回：

```json
{
  "ranked_candidates": ["会议", "回忆", "会意", "汇译"],
  "scores": [0.91, 0.73, 0.68, 0.41],
  "latency_ms": 6.2
}
```

## 模型准备

使用 `../third_party/alpha-input/script/` 里的脚本：

- `export_onnx.py`
- `export_embeddings_lmdb.py`

本仓库也提供了可用于 Qwen3 的导出脚本：

- `export_qwen_feature_onnx.py`

准备完成后，把实际路径写进 `config.toml`。

## 启动

```powershell
cargo build --release --manifest-path alpha_backend/Cargo.toml
.\Start-AlphaRerankBackend.ps1
```

首次运行如果没有 `config.toml`，脚本会从 `config.example.toml` 复制一份给你。  
当前默认示例配置已指向项目内的 `Qwen3-0.6B + ONNX + LMDB` 资产。

## 停止

```powershell
.\Stop-AlphaRerankBackend.ps1
```
