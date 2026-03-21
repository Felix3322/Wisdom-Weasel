# Third-Party Notices

## alpha-input

- Upstream: `fukege/alpha-input`
- Local copy: `/third_party/alpha-input`
- Usage in this repository:
  - `alpha_backend/` 通过 path dependency 直接复用其 Rust 实现
  - Wisdom-Weasel 的有拼音实时重排服务基于该实现提供 HTTP 接口
- Distribution note:
  - 本仓库按 GPL-3.0 分发
  - 请在正式发布前把你与上游作者关于“可直接使用其代码、仓库需保持 GPL-3”的授权记录一并归档到项目发布材料中

## rime_wanxiang

- Upstream: `amzxyz/rime_wanxiang`
- Local copy: `/third_party/rime_wanxiang`
- Upstream license: CC-BY-4.0
- Usage in this repository:
  - 作为 Rime 长句引擎与基础词库资源包
  - 通过安装脚本部署到用户 Rime 目录
