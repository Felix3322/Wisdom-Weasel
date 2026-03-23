# Wisdom-Weasel
<img width="702" height="111" alt="image" src="https://github.com/user-attachments/assets/009c5e2d-4299-42da-b291-62974635e3a7" />
<img width="688" height="97" alt="image" src="https://github.com/user-attachments/assets/d77ae687-9844-4a05-b38b-3e82c6093aab" />
<img width="655" height="87" alt="image" src="https://github.com/user-attachments/assets/f4bc8f3f-1cc3-436f-9e3e-4054fd643ed3" />

可以说爆杀微信输入法。吃了词库的红利，但是这也是微信的不足。微信算是机器学习的T1了，T0豆包没有电脑版，而且隐私风险太大

| 场景上下文 (Context) | 输入 (Pinyin) | 预期结果 | Alpha 向量排序 | 微信输入法表现 |
| --- | --- | --- | --- | --- |
| 马上要考试了，我需要开始... | fx | 复习 | 复习 ✅ | 复习 ✅ |
| 下周要去杭州出差，先把酒店和... | jp | 机票 | 机票 ✅ | 机票 ✅ |
| 明天要发布新版本，先把发布说明和... | bg | 变更日志 | 变更日志 ✅ | 报告 ❌ |
| 明天要上台主持活动，今晚把... | zc | 主持词 | 主持词 ✅ | 支持 ❌ |
| 这两天一直咳嗽发烧，下午得去... | yy | 医院 | 医院 ✅ | 医院 ✅ |
| 今晚继续优化输入法 DLL 的... | cp | 重排延迟 | 重排延迟 ✅ | 产品 ❌ |
| 老师说明天考高数，我打算先做几套... | zt | 真题 | 真题 ✅ | 状态 ❌ |

在小狼毫（Weasel）基础上，整合三层能力：

1. **万象拼音**：负责词库、语法模型、长句能力与 Rime 方案层
2. **v2端到端 transformer**：直接从拼音到文字可以更智能的修复 typo 使用 A100 训练 12 小时
3. **Alpha 重排**：负责有拼音场景下的候选实时排序
4. **LLM 预测**：负责无拼音预测、多后端推理与上下文联想
scukeqi/Wisdom-Weasel的绝大部分代码已经被改写

---

## 当前架构
<img width="598" height="407" alt="image" src="https://github.com/user-attachments/assets/ca3e2403-ea07-4d1e-9a37-9f5acb7bf77b" />

### 有拼音输入

```text
拼音输入
-> 万象拼音生成候选
-> Alpha 对候选重排
-> 第一候选固定，后续候选低延迟重排
-> v2 引擎完成计算 异步插入到最后 放置序号变化影响输入
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

- `wanxiang`
- `wanxiang_pro`

三层职责固定为：

- 万象：**方案层 / 长句语法层**
- Alpha：**候选排序层**
- LLM：**你自己的预测层**

三者不再混用。

---

## Release 资产策略

现在的发行版默认产出三类资产：

- `Wisdom-Weasel-installer-<version>.exe`
- `Wisdom-Weasel-bootstrap-<version>.zip`
- `Wisdom-Weasel-runtime-<version>.zip`

不再发布 Alpha 模型大资产。

这样做的目的：

- 避免上传超大 Release 文件
- 不要求你手动上传多段模型包
- 安装器 EXE 在安装时直接从 **Hugging Face** 下载推荐模型，并在本机转换

---

## 一键安装

推荐直接双击 Release 里的：

```text
Wisdom-Weasel-installer-<version>.exe
```

也可以在 bootstrap 包里双击：

```text
Install-Wisdom-Weasel.cmd
```

或运行：

```powershell
.\scripts\Install-Wisdom-Weasel.ps1
```

安装器 EXE / bootstrap 脚本都会：

1. 让用户选择安装目录  
   - 默认建议：`C:\Program Files\Rime\weasel-0.17.4`
2. 从 GitHub Release 下载 `runtime` 包
3. 从 GitHub 仓库下载源码快照
4. 安装万象到 Rime 用户目录
5. 安装 Alpha 运行时 DLL
6. 弹出 Alpha 模型安装方式选择：
   - **从 HF 下载推荐模型并本地转换**
   - **选择本地已下载的 HF 模型目录并转换**
   - **暂时跳过**
7. 自动写入 `wanxiang.custom.yaml` / `wanxiang_pro.custom.yaml`
8. 自动部署 Rime
9. 打开 GUI，引导用户继续勾选方案

---

## Alpha 模型安装方式

推荐模型：

```text
Qwen/Qwen3-0.6B
```

安装器在“自动下载并转换”模式下会：

1. 创建临时 Python 虚拟环境
2. 安装导出依赖
3. 从 Hugging Face 下载推荐模型
4. 本地导出：
   - `alpha_backend/model/qwen3-0.6b-onnx-int8`
   - `alpha_backend/model/qwen3-0.6b-embeddings_lmdb`
5. 生成 Rime 使用的 `alpha_rerank_config.toml`
6. 自动启用 Alpha 重排

说明：自动下载/转换需要本机可用 **Python 3**（安装器会自动创建临时 venv）。

如果你选择“本地模型目录”，安装器会直接用你现有的 HF 模型目录做本地转换，不再重复下载。

如果你选择“跳过”：

- 有现有模型：继续复用
- 没有现有模型：Alpha 保持关闭，但万象和 LLM 安装不受影响

---

## GUI 后续引导

安装完成后，建议在 GUI 中完成以下动作：

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

安装器会写入：

```yaml
patch:
  alpha_rerank/enabled: true
  alpha_rerank/max_candidates: 6
  alpha_rerank/max_negative_candidates: 3
  alpha_rerank/context_max_chars: 64
  alpha_rerank/recent_tail_chars: 16
  alpha_rerank/order_prior_weight: 0.02
```

特性：

- 第一候选不改
- 只重排后续候选
- 根据用户上屏结果累积长期 / 会话偏好向量
- 用户跳过更高排位候选时，会给这些候选轻量负反馈
- 自动截断长上下文
- 面向 CPU 实时场景

偏好相关参数位于：

- `alpha_backend/config.toml`
- `[preference]` 段

默认会把长期偏好持久化到：

- `alpha_backend/user_preference.json`

### Alpha 重排场景测试（2026-03-21，当前 Rime 部署配置）

测试环境：

- DLL：`AppData/Rime/lua/wanxiang/alpha_input.dll`
- 配置：`AppData/Rime/lua/wanxiang/alpha_rerank_config.toml`
- 模型：`qwen3-0.6b-onnx-int8`
- 偏好：关闭
- `order_prior_weight = 0.02`

可以说爆杀微信输入法（下面是微信测试，由于WX的排序DLL未知，只能手动测试，可能没那么完整，但是一样准确）
吃了词库的红利，但是这也是微信的不足

| 场景上下文 (Context) | 输入 (Pinyin) | 预期结果 | Alpha 向量排序 | 微信输入法表现 |
| --- | --- | --- | --- | --- |
| 马上要考试了，我需要开始... | fx | 复习 | 复习 ✅ | 复习 ✅ |
| 下周要去杭州出差，先把酒店和... | jp | 机票 | 机票 ✅ | 机票 ✅ |
| 明天要发布新版本，先把发布说明和... | bg | 变更日志 | 变更日志 ✅ | 报告 ❌ |
| 明天要上台主持活动，今晚把... | zc | 主持词 | 主持词 ✅ | 支持 ❌ |
| 这两天一直咳嗽发烧，下午得去... | yy | 医院 | 医院 ✅ | 医院 ✅ |
| 今晚继续优化输入法 DLL 的... | cp | 重排延迟 | 重排延迟 ✅ | 产品 ❌ |
| 老师说明天考高数，我打算先做几套... | zt | 真题 | 真题 ✅ | 状态 ❌ |

### LLM 无拼音预测

当前默认策略：

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

- `archives/Wisdom-Weasel-installer-<version>.exe`
- `archives/Wisdom-Weasel-bootstrap-<version>.zip`
- `archives/Wisdom-Weasel-runtime-<version>.zip`

---

## 重要脚本

- `scripts/Install-Wisdom-Weasel.ps1`
  - 一键安装发行版
- `scripts/Install-RimeWanxiang.ps1`
  - 单独安装万象到 Rime 用户目录
- `scripts/Build-ReleaseBundle.ps1`
  - 生成 installer exe + bootstrap zip + runtime zip

---

## 文档

- 最终架构说明：`docs/final_architecture.md`
- Alpha 集成说明：`docs/alpha_rerank_integration.md`

---

## 致谢

感谢 [scukeqi/Wisdom-Weasel](https://github.com/scukeqi/Wisdom-Weasel) 与
[fukege/alpha-input](https://github.com/fukege/alpha-input) 提供思路与启发。  
本项目为独立实现，代码并非来自上述项目。
