# Wisdom-Weasel Alpha 实时重排集成方案

## 最终行为

- **有拼音输入**
  - 只做实时重排
  - 候选池完全来自 Rime / 万象方案
  - 不再调用后续 LLM 长句生成
- **无拼音输入**
  - 保持现有 Wisdom-Weasel 预测链路不变

## 当前推荐架构

### 1. Rime 侧 filter

- `third_party/rime_wanxiang/lua/wanxiang/alpha_rerank.lua`

这个 Lua filter 现在负责：

- 读取当前 `commit_history`
- 组装 Alpha 重排上下文
- 执行三路分支融合
  - `用户输入记录：...`
  - 原始最近上下文
  - 最近输入片段
- 叠加轻量原始顺序先验
- 直接改写候选输出顺序

### 2. Rime Lua 原生扩展

- `RimeLuaAlpha/alpha_rerank_core.cpp`
- 构建产物：`alpha_rerank_core.dll`

职责：

- 作为 Lua C module 暴露给 `alpha_rerank.lua`
- 在进程内直接加载 `alpha_input.dll`
- 复用 `alpha_predictive_compute_similarities_ordered()` 能力

### 3. Alpha 核心库

- `/third_party/alpha-input`

职责：

- 加载 ONNX / tokenizer / LMDB
- 计算上下文与候选的相似度

### 4. Rime 方案资源

- `/third_party/rime_wanxiang`

通过部署脚本复制到 Rime 用户目录，作为：

- 长句引擎
- 基础词库
- Lua 扩展

## 与旧方案的区别

旧方案：

- `Weasel -> Alpha HTTP server -> alpha-input`

新推荐方案：

- `Rime filter -> alpha_rerank_core.dll -> alpha_input.dll`

变化点：

- **不再要求常驻 HTTP 服务**
- **排序策略迁到 Lua filter，更方便热更新和迭代**
- `alpha_backend/config.toml` 仍可继续复用，避免重写现有模型路径配置

## 启动顺序

1. 安装万象方案到 Rime 用户目录
2. 构建 `alpha_input.dll`
3. 构建 `alpha_rerank_core.dll`
4. 把运行时文件复制到 `Rime/lua/wanxiang/`
5. 在方案 patch 中启用 `alpha_rerank`
6. 重新部署 Rime

## 构建与部署

```powershell
.\build.bat x64
cargo build --release --manifest-path third_party/alpha-input/Cargo.toml
.\scripts\Install-RimeWanxiang.ps1
```

`Install-RimeWanxiang.ps1` 会在文件存在时额外复制：

- `alpha_rerank_core.dll`
- `alpha_input.dll`
- `onnxruntime.dll`
- `onnxruntime_providers_shared.dll`
- `alpha_rerank_config.example.toml`

到：

- `Rime/lua/wanxiang/`

若 `third_party/alpha-input/target/release/` 不存在，脚本会自动回退到 `alpha_backend/target/release/` 寻找同名运行时文件。

## 建议的方案 patch

放到 `wanxiang.custom.yaml` / `wanxiang_pro.custom.yaml`：

```yaml
patch:
  alpha_rerank/enabled: true
  alpha_rerank/config_path: "C:/Users/your-name/CLionProjects/Wisdom-Weasel/alpha_backend/config.toml"
  alpha_rerank/dll_path: "C:/Users/your-name/AppData/Roaming/Rime/lua/wanxiang/alpha_input.dll"
```

如果 `alpha_input.dll` 已经放在 `Rime/lua/wanxiang/`，`dll_path` 可以留空。

## 兼容性说明

- `llm/pinyin_rerank/alpha_http` 旧链路暂未删除，仍可作为兼容 fallback
- 但默认推荐已经改为 **Rime filter 内重排**
