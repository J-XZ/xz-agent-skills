---
name: check
description: 对本技能合集的运行环境执行一次性自检：检查技能完整性、OpenCode 及子代理定义是否存在、配置模型是否有效并能真实响应，最后给出合集是否可用的结论及修改建议。仅在用户主动要求检查环境、验证 skill 可用性或调用 check 时使用；日常编程任务不自动触发。
---

# 环境与技能可用性自检

仅在用户主动要求检查时执行。全过程保持只读，不修改项目代码、不改动用户配置；探针完成后清理临时状态。

## 检查项

按顺序执行并记录每项结果（`PASS` / `WARN` / `FAIL`）与实际证据：

1. **技能完整性**
   - 核对 `main-worker`、`work-rules`、`perf-evidence` 及 `perf-evidence/references/experiment.md` 等关键文件存在且可读。
2. **OpenCode 与子代理定义**
   - 检查本机/环境中的 `opencode` 是否可调用（如 `opencode --version`）。
   - 读取 `~/.config/opencode/opencode.jsonc`（或当前生效配置），检查是否定义了 `agents.worker` 与 `agents.reviewer`，核对两者的 `mode: "subagent"`、`model`（格式为 `provider/model` 或 `provider/model#variant`），以及 `reviewer` 是否配置了只读编辑拒绝规则。
3. **模型存在性检查**
   - 通过 `opencode models`（若可用）核对 `worker` 与 `reviewer` 配置的模型是否在当前可用模型列表中；无法列出时标记 `WARN` 并以实测响应为准。
4. **子代理真实响应探针**
   - 分别向 `worker` 与 `reviewer` 子代理派发一次最小只读探针：要求仅回复 `PONG`，不读写任何文件、不执行任何命令。
   - 记录是否成功返回 `PONG`、耗时、退出状态及报错；若宿主返回实际使用模型，核对是否与配置一致。

## 输出格式

按以下结构输出最终诊断报告：

- **总体结论**：`可用` / `部分可用` / `不可用`
- **逐项结果**：列出上述 4 项的状态（`PASS` / `WARN` / `FAIL`）及关键事实（版本、配置路径、模型名、探针回复或报错摘要）
- **修改建议**：针对每一项 `FAIL` 或 `WARN` 给出具体、可执行的修复步骤（如安装或升级 OpenCode、在 `~/.config/opencode/opencode.jsonc` 补全 `worker`/`reviewer` 定义、修正模型 ID 或提供商鉴权、重新运行 `scripts/install.sh`）；全部通过时写“无”。
