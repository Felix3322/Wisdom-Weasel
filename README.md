# Wisdom-Weasel

在小狼毫（Weasel）基础上，整合三层能力：

1. **万象拼音**：负责词库、语法模型、长句与 Rime 方案层能力
2. **Alpha 重排**：负责有拼音场景下的候选实时排序
3. **LLM 预测**：负责无拼音预测、多后端推理与上下文联想

---

## 当前架构

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

## 默认内置内容

### Rime 方案

- `wanxiang`
- `wanxiang_pro`

### Alpha CPU 实时重排默认模型

- `qwen3-0.6b-onnx-int8`
- `qwen3-0.6b-embeddings_lmdb`

### LLM 预测后端

- `openai`
- `llamacpp`
- `hf_constraint`

---

## 发行版安装方式

发行版会附带：

- 编译后的 `output/`
- 万象方案文件
- Alpha runtime
- Alpha 模型文件
- 一键安装脚本

### 一键安装入口

双击：

```text
Install-Wisdom-Weasel.cmd
```

或运行：

```powershell
.\scripts\Install-Wisdom-Weasel.ps1
```

安装器会：

1. 让用户选择安装目录  
   - 默认建议：`C:\Program Files\Rime\weasel-0.17.4`
2. 用发行包中的 `output/` 覆盖目标目录
3. 复制 Alpha 模型与运行时
4. 安装万象到用户 Rime 目录
5. 自动生成并启用 `alpha_rerank` 配置
6. 重新部署 Rime
7. 打开 GUI 与用户目录，引导用户继续调整配置

---

## GUI 后续引导

安装完成后，建议用户在 GUI 中完成以下动作：

1. 打开 **小狼毫输入法设定**
2. 勾选：
   - `wanxiang`
   - `wanxiang_pro`
3. 检查或修改：
   - `weasel.custom.yaml`
   - `wanxiang.custom.yaml`
   - `wanxiang_pro.custom.yaml`

---

## 关键配置

### Alpha 重排

安装器会自动生成：

```yaml
patch:
  alpha_rerank/enabled: true
  alpha_rerank/max_candidates: 6
  alpha_rerank/context_max_chars: 64
  alpha_rerank/recent_tail_chars: 16
  alpha_rerank/order_prior_weight: 0.02
```

特性：

- 第一候选不改
- 只重排后续候选
- 自动截断长上下文
- 适配 CPU 实时场景

### LLM 无拼音预测

当前本地 Ollama 路径下默认策略：

- 先给一个**短结果**
- 再补一个**短语**
- 再补一个**长句**

目的是降低首候选等待时间，同时保持补全丰富度。

---

## 从源码构建

PowerShell 推荐：

```powershell
$env:DEVTOOLS_PATH='C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\amd64;'
.\build.bat rebuild x64
```

### 生成发行包

```powershell
.\scripts\Build-ReleaseBundle.ps1
```

生成结果：

- 发行目录：`archives/Wisdom-Weasel-<version>/`
- 压缩包：`archives/Wisdom-Weasel-<version>-bundle.7z`

---

## 重要脚本

- `scripts/Install-Wisdom-Weasel.ps1`
  - 一键安装发行版
- `scripts/Install-RimeWanxiang.ps1`
  - 单独安装万象到 Rime 用户目录
- `scripts/Build-ReleaseBundle.ps1`
  - 组装发行目录并打包

---

## 文档

- 最终架构说明：`docs/final_architecture.md`
- Alpha 集成说明：`docs/alpha_rerank_integration.md`

---

## 备注

- 万象是**方案层 / 长句语法层**
- Alpha 是**候选排序层**
- LLM 是**你自己的预测层**

三者职责分离，不再混用。
