# Wisdom-Weasel

<img width="702" height="111" alt="image" src="https://github.com/user-attachments/assets/009c5e2d-4299-42da-b291-62974635e3a7" />
<img width="688" height="97" alt="image" src="https://github.com/user-attachments/assets/d77ae687-9844-4a05-b38b-3e82c6093aab" />
<img width="655" height="87" alt="image" src="https://github.com/user-attachments/assets/f4bc8f3f-1cc3-436f-9e3e-4054fd643ed3" />

Wisdom-Weasel 基于小狼毫（Weasel）继续演进，固定拆分为三层能力：

1. **万象拼音**：词库、语法模型、长句能力、Rime 方案层
2. **Alpha 重排**：有拼音输入时的候选实时排序
3. **LLM 预测**：无拼音预测、多后端推理、上下文联想

`scukeqi/Wisdom-Weasel` 的绝大部分代码已经被重写，目标是把三层职责彻底分开，避免方案层、排序层、预测层继续互相耦合。

---

## 当前架构

<img width="598" height="407" alt="image" src="https://github.com/user-attachments/assets/ca3e2403-ea07-4d1e-9a37-9f5acb7bf77b" />

### 有拼音输入

```text
拼音输入
-> 万象拼音生成候选
-> Alpha 对候选重排
-> 第一候选固定，后续候选低延迟重排
```

### 无拼音输入

```text
最近上下文
-> LLM provider
-> 先给一个短结果
-> 再补一个短语
-> 再补一个长句
```

---

## 方案与职责

当前主要方案：

- `wanxiang`
- `wanxiang_pro`

三层职责固定为：

- 万象：**方案层 / 长句语法层**
- Alpha：**候选排序层**
- LLM：**你自己的预测层**

三者不再混用。

---

## Release 资产策略

发行版现在只保留下面几类正式资产：

- `Wisdom-Weasel-installer-<version>.exe`
- `Wisdom-Weasel-bootstrap-<version>.zip`
- `Wisdom-Weasel-runtime-<version>.zip`

构建脚本还会额外生成一个清单文件：

- `Wisdom-Weasel-release-assets-<version>.txt`

这个清单文件只用于提醒维护者“应该上传哪 3 个正式资产”。

### 明确约束

**Release 不再包含任何 Alpha 模型资产**，也不应该再上传：

- `Wisdom-Weasel-model-*`
- 原始 Hugging Face 模型快照
- 分卷模型包

Alpha 模型的处理方式已经改为：

1. 安装器在目标机器上从 **Hugging Face** 下载原始模型到**临时目录**
2. 在目标机器上本地执行导出 / 量化 / LMDB 构建
3. 安装目录最终只保留：
   - `alpha_backend/model/qwen3-0.6b-onnx-int8`
   - `alpha_backend/model/qwen3-0.6b-embeddings_lmdb`

这样做的目的：

- 避免 Release 被超大模型文件污染
- 减少维护者手动切分 / 上传模型包
- 安装器自动完成“下载 + 转换 + 启用”
- 安装目录不再长期保留原始 HF 快照

---

## 安装前准备

推荐环境：

- Windows 10 / 11
- 已安装或准备覆盖安装小狼毫目录
- 有管理员权限
- 能访问 GitHub Release
- 如果要自动安装 Ollama 预测：能访问 `ollama.com`
- 如果要自动安装 Alpha 模型：能访问 Hugging Face
- 如果要自动转换 Alpha 模型：本机可用 **Python 3**

可选环境变量：

- `GITHUB_TOKEN` 或 `GH_TOKEN`
  - 用于缓解 GitHub API rate limit

如果你的网络不方便直接访问 Hugging Face，建议先手动把模型下载到本地，再使用“**本地模型目录转换**”模式。

---

## 详细安装说明

## 1. 推荐方式：直接运行安装器 EXE

从 Release 下载：

```text
Wisdom-Weasel-installer-<version>.exe
```

双击后会启动引导安装器。

### 安装器会做什么

安装器会依次完成：

1. 请求管理员权限
2. 让你选择 Wisdom-Weasel 的安装目录
   - 默认建议：`C:\Program Files\Rime\weasel-0.17.4`
3. 从 GitHub Release 下载 `runtime` 包
4. 从 GitHub 仓库下载对应版本源码快照
5. 安装万象到 Rime 用户目录
6. 安装 Alpha 运行时 DLL
7. 自动安装或确认本机 Ollama
8. 自动检测当前机器配置（CPU / 核心数 / 内存 / 显卡显存）
9. 弹出模型选择窗口，并按当前机器**预选推荐模型**
   - 例如：`qwen3:0.6b` / `qwen3:1.7b` / `qwen3:4b` / `qwen3:8b` / `qwen3:14b`
   - 也支持输入你自己的 Ollama 模型名
10. 自动拉取你选中的 Ollama 预测模型
11. 自动备份并写入 `weasel.custom.yaml`
   - 如果已有旧配置，会生成同目录时间戳备份
12. 询问 Alpha 模型安装方式：
   - **自动从 Hugging Face 下载并本地转换**
   - **使用本地已下载模型目录并本地转换**
   - **暂时跳过**
13. 自动写入 `wanxiang.custom.yaml` / `wanxiang_pro.custom.yaml`
14. 自动部署 Rime
15. 打开 GUI，引导你继续勾选方案

### 安装完成后你会得到什么

如果选择了 Alpha 自动安装，安装目录最终只保留转换后的运行时模型：

```text
alpha_backend/model/qwen3-0.6b-onnx-int8
alpha_backend/model/qwen3-0.6b-embeddings_lmdb
```

原始 Hugging Face 下载目录只存在于安装时的临时工作目录里，安装结束后会清理。

同时，安装器还会把 `weasel.custom.yaml` 自动切到 **Ollama 本地预测**，默认写入：

```yaml
patch:
  "llm/enabled": true
  "llm/provider_type": openai
  "llm/openai/api_url": "http://127.0.0.1:11434/v1/chat/completions"
  "llm/openai/api_key": ""
  "llm/openai/model": "<安装时选择的 Ollama 模型>"
```

如果该文件此前已经存在，安装器会先创建类似下面的备份：

```text
weasel.custom.yaml.pre-wisdom-weasel-ollama.<timestamp>.bak
```

---

## 2. 备用方式：使用 bootstrap 包

如果你不想直接运行 EXE，也可以下载：

```text
Wisdom-Weasel-bootstrap-<version>.zip
```

解压后双击：

```text
Install-Wisdom-Weasel.cmd
```

或者手动执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-Wisdom-Weasel.ps1
```

bootstrap 包本身不包含运行时和模型，只包含引导脚本；执行后仍会在线下载 `runtime` 资产，并按你选择决定是否从 HF 下载模型。

---

## 3. Ollama 预测现在默认开箱即用

安装器现在默认会把 **Ollama 本地预测** 一起装好，目标是安装完成后无需你手动改 `weasel.custom.yaml`。

默认行为：

1. 自动安装 / 确认 Ollama
2. 自动等待本地 API 就绪：`http://127.0.0.1:11434`
3. 自动检测当前机器配置
4. 自动给出**推荐模型**，并允许你手动改选
5. 自动拉取你选择的 Ollama 模型
6. 自动备份旧的 `weasel.custom.yaml`
7. 自动写入 Wisdom-Weasel 管理的 Ollama LLM 配置
8. 自动重新部署 Rime

也就是说，**Ollama 预测现在默认就是“完全开箱即用”路径**。

如果你后面想换模型，只需要改：

```yaml
"llm/openai/model"
```

比如改成别的 Ollama 模型名后重新部署即可。

### 当前内置推荐档位

- `qwen3:0.6b`
  - 轻量档，适合低内存 / 纯 CPU
- `qwen3:1.7b`
  - 均衡档，适合大多数办公机
- `qwen3:4b`
  - 质量更高，适合 16GB+ 内存或有独显
- `qwen3:8b`
  - 高质量档，适合高内存 / 6GB+ 显存
- `qwen3:14b`
  - 高性能机器可选

### 关于 CPU 指令集优化

Ollama 本身会在支持的机器上自动使用更合适的 CPU 指令集路径（例如 AVX / AVX2）。  
因此当前安装器主要负责：

- 根据机器配置推荐模型
- 让你自己选择模型

而不是额外再手工写一层 CPU 指令集开关。

---

## 4. Alpha 模型安装方式详解

当前默认推荐模型：

```text
Qwen/Qwen3-0.6B
```

### 方式 A：自动下载并转换（推荐）

适合：

- 能访问 Hugging Face
- 本机有 Python 3
- 不想手动处理模型文件

安装器会：

1. 创建临时 Python venv
2. 安装导出依赖
3. 从 Hugging Face 下载推荐模型到临时目录
4. 本地导出 ONNX（int8）
5. 本地构建 embeddings LMDB
6. 写入 `alpha_rerank_config.toml`
7. 自动启用 Alpha 重排

### 方式 B：使用本地模型目录并转换

适合：

- 你的网络不方便直接访问 HF
- 你已经手动下载过 HF 模型目录
- 希望把下载和转换拆开

你选择本地目录时，目录里通常应包含这类文件：

- `config.json`
- tokenizer 相关文件
- `*.safetensors`

安装器只负责“本地转换”，不会重复下载。

### 方式 C：暂时跳过

适合：

- 先把输入法主体装起来
- 稍后再补装 Alpha

此时的行为：

- 如果已有可用 Alpha 模型：继续复用
- 如果没有可用 Alpha 模型：Alpha 保持关闭
- 万象 / LLM 的安装不受影响

---

## 5. 安装后如何补装 Alpha 模型

以后想补装或重装 Alpha 时，可以重新运行安装器脚本。

例如自动下载并转换：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-Wisdom-Weasel.ps1 -ModelSetup auto
```

使用本地目录转换：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-Wisdom-Weasel.ps1 -ModelSetup local -LocalModelDir D:\models\Qwen3-0.6B
```

如果你只想更新模型，不想再弹出最后的 GUI 引导，可以附加：

```powershell
-SkipGuiGuide
```

---

## 6. 安装完成后的 GUI 引导

安装完成后，建议立刻在 GUI 中完成这些动作：

1. 打开 **小狼毫输入法设定**
2. 勾选：
   - `wanxiang`
   - `wanxiang_pro`
3. 检查或按需修改：
   - `weasel.custom.yaml`
   - `wanxiang.custom.yaml`
   - `wanxiang_pro.custom.yaml`

如果安装器检测到 Alpha 模型已经可用，会自动写好 Alpha 重排补丁和配置。

---

## 7. 常见问题

### Q1：为什么 Release 里没有模型？

因为模型太大，不适合继续作为 Release 资产维护。现在的设计是：

- Release 只发安装器 / bootstrap / runtime
- 模型在用户机器上从 Hugging Face 下载
- 然后在用户机器上本地转换

### Q2：没有 Python 3 可以吗？

可以安装主体，但：

- 自动安装 Alpha 模型需要 Python 3
- 如果没有 Python 3，就只能先跳过 Alpha，或先自己准备好转换环境

### Q3：没有 Python 3，会影响 Ollama 预测吗？

不会。

- **Ollama 预测安装不依赖 Python 3**
- Python 3 只用于 **Alpha 模型的 HF 下载与本地转换**

### Q4：我可以自己选 Ollama 模型吗？

可以。

- 安装器会先根据你的机器配置给出推荐模型
- 但你可以在安装窗口里手动改选
- 也可以直接输入自定义 Ollama 模型名

### Q5：Hugging Face 下载慢怎么办？

两种方案：

1. 先自己下载 HF 模型，再用“本地模型目录转换”
2. 用代理 / 镜像后再运行自动安装

### Q6：为什么安装器还要下载源码快照？

因为安装万象、导出 Alpha ONNX、构建 embeddings LMDB 都依赖仓库中的脚本和资源文件。当前 bootstrap 只放引导逻辑，不把这些源码资源直接塞进 EXE。

### Q7：安装器会不会覆盖我原来的 `weasel.custom.yaml`？

会自动改，但会先备份。

- 如果安装器发现旧的 `weasel.custom.yaml`
- 会先在同目录生成带时间戳的 `.bak`
- 然后再写入 Wisdom-Weasel 管理的 Ollama 配置块

这样你始终可以回滚。

---

## 关键配置

### 自动写入的 Ollama 预测配置

安装器会自动备份并更新：

- `%APPDATA%\Rime\weasel.custom.yaml`

默认写入的核心配置类似：

```yaml
patch:
  "llm/enabled": true
  "llm/provider_type": openai
  "llm/developer_mode": false
  "llm/context_recent_words": 20
  "llm/context_max_chars": 160
  "llm/input_prediction_debounce_ms": 120
  "llm/openai/api_url": "http://127.0.0.1:11434/v1/chat/completions"
  "llm/openai/api_key": ""
  "llm/openai/model": "<安装时选择的 Ollama 模型>"
  "llm/openai/max_tokens": 20
  "llm/openai/temperature": "0.6"
```

说明：

- `provider_type` 仍然是 `openai`
- 这是因为 Wisdom-Weasel 直接把 **Ollama 当作 OpenAI-compatible API** 来调用
- 当 API 地址是 `localhost:11434` 时，程序会自动走 Ollama 的本地 continuation 优化逻辑

### Alpha 重排补丁

安装器会写入：

```yaml
patch:
  alpha_rerank/enabled: true
  alpha_rerank/config_path: "<Rime 用户目录>/lua/wanxiang/alpha_rerank_config.toml"
  alpha_rerank/dll_path: "<Rime 用户目录>/lua/wanxiang/alpha_input.dll"
  alpha_rerank/max_candidates: 6
  alpha_rerank/context_max_chars: 64
  alpha_rerank/recent_tail_chars: 16
  alpha_rerank/order_prior_weight: 0.02
  alpha_rerank/log_enabled: false
```

特性：

- 第一候选不改
- 只重排后续候选
- 可累积长期 / 会话偏好向量
- 可对“被跳过的更高排位候选”施加轻量负反馈
- 自动截断长上下文
- 面向 CPU 实时场景

偏好相关参数位于：

- `alpha_backend/config.toml`
- `[preference]` 段

默认长期偏好持久化文件：

- `alpha_backend/user_preference.json`

### LLM 无拼音预测

当前默认策略：

- 先给一个**短结果**
- 再补一个**短语**
- 再补一个**长句**

目标是尽快给出首个候选，再逐步补全更丰富内容。

---

## Alpha 重排场景测试（2026-03-21，当前 Rime 部署配置）

测试环境：

- DLL：`AppData/Rime/lua/wanxiang/alpha_input.dll`
- 配置：`AppData/Rime/lua/wanxiang/alpha_rerank_config.toml`
- 模型：`qwen3-0.6b-onnx-int8`
- 偏好：关闭
- `order_prior_weight = 0.02`

可以说爆杀微信输入法（下面是微信测试，由于 WX 的排序 DLL 未知，只能手动测试，可能没那么完整，但一样准确）。  
吃了词库的红利，但这也是微信的不足。

| 场景上下文 (Context) | 输入 (Pinyin) | 预期结果 | 本 DLL 表现 | 微信输入法表现 |
| --- | --- | --- | --- | --- |
| 马上要考试了，我需要开始... | fx | 复习 | 复习 ✅ | 复习 ✅ |
| 下周要去杭州出差，先把酒店和... | jp | 机票 | 机票 ✅ | 机票 ✅ |
| 明天要发布新版本，先把发布说明和... | bg | 变更日志 | 变更日志 ✅ | 报告 ❌ |
| 明天要上台主持活动，今晚把... | zc | 主持词 | 主持词 ✅ | 支持 ❌ |
| 这两天一直咳嗽发烧，下午得去... | yy | 医院 | 医院 ✅ | 医院 ✅ |
| 今晚继续优化输入法 DLL 的... | cp | 重排延迟 | 重排延迟 ✅ | 产品 ❌ |
| 老师说明天考高数，我打算先做几套... | zt | 真题 | 真题 ✅ | 状态 ❌ |

---

## 从源码构建

PowerShell 推荐：

```powershell
$env:DEVTOOLS_PATH='C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\amd64;'
.\build.bat rebuild x64
```

---

## 生成发行包

推荐直接执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-ReleaseBundle.ps1 -InstallerBackend auto
```

`-InstallerBackend` 说明：

- `auto`
  - 优先使用 **NSIS**
  - 如果当前机器没有安装 NSIS，则自动回退到 IExpress
- `nsis`
  - 强制使用 NSIS 生成更好的 GUI bootstrap 安装器
- `iexpress`
  - 强制使用 IExpress

生成结果：

- `archives/Wisdom-Weasel-installer-<version>.exe`
- `archives/Wisdom-Weasel-bootstrap-<version>.zip`
- `archives/Wisdom-Weasel-runtime-<version>.zip`
- `archives/Wisdom-Weasel-release-assets-<version>.txt`

### 维护者注意事项

发布 Release 时，请只上传清单文件里列出的三个正式资产。  
不要上传任何：

- `Wisdom-Weasel-model-*`
- 原始 HF 模型目录
- 临时转换产物包

构建脚本会自动清理当前版本残留的 `Wisdom-Weasel-model-*` 文件，避免误传。

---

## 重要脚本

- `scripts/Install-Wisdom-Weasel.ps1`
  - 一键安装发行版
  - 自动下载 runtime
  - 自动安装 / 确认 Ollama
  - 自动检测机器配置并推荐预测模型
  - 允许用户选择或自定义 Ollama 模型
  - 自动备份并写入 `weasel.custom.yaml`
  - 自动 / 本地转换 Alpha 模型
- `scripts/Install-Wisdom-Weasel.cmd`
  - 方便双击启动，优先使用 `pwsh`
- `scripts/Build-ReleaseBundle.ps1`
  - 生成 installer / bootstrap / runtime
  - 生成 Release 资产清单
  - 清理当前版本残留模型资产
- `scripts/Wisdom-Weasel-bootstrap-installer.nsi`
  - NSIS bootstrap 安装器模板

---

## 当前安装流程总结

一句话概括现在的策略：

> **Release 只发安装器和运行时，不发 Alpha 模型；安装器会自动把 Ollama 预测配好，并把 Alpha 模型从 Hugging Face 下载到本机临时目录后完成转换。**
