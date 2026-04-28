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
- 维护最近一次展示给用户的 rerank 候选快照
- 在用户上屏后，把“选中的候选”作为正反馈，把“排在它前面但没被选中”的候选作为负反馈
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
- 暴露 `apply_user_feedback()` / `update_user_preference()` 给 Lua

### 3. Alpha 核心库

- `/third_party/alpha-input`

职责：

- 加载 ONNX / tokenizer / LMDB
- 计算上下文与候选的相似度
- 缓存 query/context 向量
- 缓存候选 embedding
- 维护用户偏好：
  - session positive vector
  - long-term positive vector
  - session negative vector
  - long-term negative vector
- 将长期偏好持久化到 `user_preference.json`

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
  alpha_rerank/max_candidates: 6
  alpha_rerank/max_negative_candidates: 3
```

如果 `alpha_input.dll` 已经放在 `Rime/lua/wanxiang/`，`dll_path` 可以留空。

## 当前打分逻辑（2026-03）

旧版 DLL 主链路里的候选分数可以概括为：

```text
final_score
  = semantic_score(context, candidate)
  + preference_score(candidate)
  + order_prior
```

其中：

- `semantic_score`
  - 由 `alpha_input.dll` 计算
  - 本质上是 `candidate_embedding` 与 `context_embedding` 的余弦相似度
- `preference_score`
  - 由正反馈和负反馈共同组成
- `order_prior`
  - Lua 侧叠加的一点原始顺序先验
  - 用于保证排序稳定性，避免分数极接近时抖动

## 当前在线融合逻辑（2026-04）

当前在线重排已经切到“分支拆分 + Lua 门控融合”：

```text
alpha_input:
  semantic_score
  preference_score
  user_frequency_score
  final_score = semantic_score + preference_score + user_frequency_score

alpha_rerank.lua:
  gated_score
    = g_semantic(candidate, context) * semantic_score
    + g_preference(candidate, context) * preference_score
    + g_user_frequency(candidate, context) * user_frequency_score
    + g_continuation(candidate, context) * continuation_prior
    + order_prior
    + quality_prior
    + input_coverage_prior
    + contrastive_bonus
```

其中：

- `semantic_score`
  - 仍来自 `alpha_input.dll`
  - 适合内容词、命名实体、长候选
- `preference_score`
  - 仍来自用户正负反馈向量
- `user_frequency_score`
  - 来自显式用户选词频次记忆
  - 用于保守拉升常用短词、中性词和高频个人用语
- `continuation_prior`
  - 在 Lua 侧根据候选类型、长度、上下文置信度、输入码长做 continuation 风格补偿
  - 专门用于把虚词、连词、单字短候选从“纯语义失真”里拉回来
- `g_semantic / g_preference / g_continuation`
  - 不是常数
  - 会随 `候选长度 / 是否虚词 / context_confidence / 输入码长 / 候选类型` 动态调整

### preference_score 细分

当前实现可近似理解为：

```text
preference_score
  = positive_weight * positive_similarity
  - negative_weight * negative_similarity
```

其中：

- `positive_similarity`
  - 来自用户过去上屏内容形成的偏好向量
- `negative_similarity`
  - 来自“用户跳过的高位候选”形成的负反馈向量

正负向量内部又分为：

- session（会话内，收敛更快）
- long-term（长期，持久化保存）

并按配置权重做混合。

## 用户偏好 / 负反馈闭环

### 正反馈来源

正反馈信号来自：

- `commit_history` 中新出现的上屏文本

当 Lua filter 发现有新的 commit 记录时，会把该文本传给 DLL，作为：

- **正反馈样本**

### 负反馈来源

负反馈不是简单地“所有没选中的都算负样本”，当前做法更保守：

1. Lua 记录**最近一次实际展示给用户的 rerank 后候选顺序**
2. 下一次发现新的 commit 时，检查这个上屏文本是否来自上一轮 rerank 候选
3. 如果用户选择的是较低排位候选，则把：
   - **排在它前面的若干个 rerank 候选**
   - 作为负反馈
4. 数量由 `alpha_rerank/max_negative_candidates` 控制

注意：

- 当前负反馈只针对 **rerank 池内部** 候选
- 固定首候选不会被直接写入负反馈向量
- 如果上屏文本无法和上一轮候选对应上，则只记正反馈，不记负反馈

### 向量更新方式

当前使用 **EMA（指数滑动平均）**：

```text
new_vector = old_vector * (1 - alpha) + sample_vector * alpha
```

优点：

- 更新成本低
- 对实时 DLL 场景友好
- 比离散词频记忆更容易泛化到语义相近候选

### 持久化

长期偏好会保存到：

- `alpha_backend/user_preference.json`
- `alpha_backend/user_frequency.json`

当前快照包含：

- positive long-term vector
- negative long-term vector
- 各自更新次数

旧版只有正反馈的 v1 快照会自动兼容读取。

## 关键配置

`alpha_backend/config.toml` / `config.example.toml` 中：

```toml
[performance]
query_cache_capacity = 128
candidate_cache_capacity = 4096

[preference]
enabled = true
persistence_path = "user_preference.json"
blend_weight = 0.12
negative_weight = 0.06
session_weight = 0.45
long_term_weight = 0.55
session_alpha = 0.25
long_term_alpha = 0.08
negative_session_alpha = 0.16
negative_long_term_alpha = 0.05
min_long_term_updates = 3
save_every_updates = 8
```

含义：

- `blend_weight`
  - 正反馈对排序的整体影响
- `negative_weight`
  - 负反馈整体惩罚强度
- `session_alpha` / `long_term_alpha`
  - 正反馈学习速度
- `negative_session_alpha` / `negative_long_term_alpha`
  - 负反馈学习速度

## 延迟现状（DLL，本地链路）

2026-03-21 本地基准，测试脚本：

- `scripts/Measure-AlphaRerankDllLatency.ps1`

链路为：

- `alpha_rerank.lua -> alpha_rerank_core.dll -> alpha_input.dll`

结果摘要：

- 初始化：约 `1.8s`
- warm steady-state：
  - `repeat_6`: avg `0.54ms`
  - `repeat_8`: avg `0.95ms`
  - `session_pref_6`: avg `0.34ms`
- 冷 miss（无 warmup 的前三次）：
  - 平均约 `19ms ~ 21ms`
  - 单次峰值约 `55ms ~ 62ms`

结论：

- **稳定态 DLL 重排已显著低于 30ms**
- **首个新上下文 miss 仍有进一步优化空间**

## 兼容性说明

- `llm/pinyin_rerank/alpha_http` 旧链路暂未删除，仍可作为兼容 fallback
- 但默认推荐已经改为 **Rime filter 内重排**
