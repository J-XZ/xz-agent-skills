---
name: check
description: 对 Antigravity 特殊版技能合集的运行环境执行一次性自检：检查插件与技能文件、OpenCode MCP 连通性、OpenCode 可调用性、agent 及模型定义是否有效并能真实响应，最后给出合集是否可用的结论及修改建议。仅在用户主动要求检查环境、验证 skill 可用性或调用 check 时使用；日常编程任务不自动触发。
compatibility: 需要启用本插件附带的 xz-agent-skills-opencode MCP 服务（宿主在沙箱外运行 OpenCode v2 CLI）。
---

# 环境与技能可用性自检（Antigravity 特殊版）

仅在用户主动要求检查时执行。全过程保持只读，不修改项目代码、不改动用户配置；所有探针通过 MCP 发起并使用 `archived: true`，不通过终端 `run_command` 直接调用 `opencode`。

## 检查项

按顺序执行并记录每项结果（`PASS` / `WARN` / `FAIL`）与实际证据：

1. **插件技能与模型定义**
   - 核对插件目录内的 `main-worker`、`work-rules`、`perf-evidence` 及 `perf-evidence/references/experiment.md` 存在且可读。
   - 读取 `main-worker/SKILL.md`「OpenCode MCP 委派」表中的执行者与审核者模型定义，确认均已配置且符合 `provider/model` 或 `provider/model#variant` 格式。
2. **MCP 服务连通性**
   - 核对 `opencode_run`、`opencode_status`、`opencode_stop`、`opencode_list_jobs` 工具已就绪。
   - 调用 `opencode_list_jobs` 验证 `xz-agent-skills-opencode` MCP 进程可正常响应，并检查是否存在异常遗留的 `running` 作业。
3. **Agent 定义检查（可选）**
   - 若用户要求通过 `--agent` 使用自定义代理（如 `worker` / `reviewer`），核对对应 OpenCode 配置中的 agent 定义是否存在；未指定自定义 `agent` 时标记 `PASS`（注明采用模型直传 + 提示词与 `workdir_changes_during_review` 约束）。
4. **OpenCode 可调用性与模型真实响应探针**
   - 使用 `opencode_run` 分别以执行者模型（`role: "worker"`）和审核者模型（`role: "reviewer"`）执行一次最小只读探针：
     - `workdir`：当前项目目录（或空白只读目录）
     - `model`：取自第 1 步读取的模型定义
     - `prompt`：`"只回复 PONG，不要读取或修改任何文件，不要执行任何命令。"`
     - `archived: true`、`wait_seconds: 30`
   - 若返回 `status: "running"`，通过 `opencode_status` 等待结果；超过合理时间仍无进展时调用 `opencode_stop` 清理并判为 `FAIL`。
   - 确认两次探针均满足：`status == "completed"`、`exit_code == 0`、`assistant_text` 为 `PONG`、`errors` 与 `stderr_tail` 为空，且审核者探针的 `workdir_changes_during_review` 为空。

## 输出格式

按以下结构输出最终诊断报告：

- **总体结论**：`可用` / `部分可用` / `不可用`
- **逐项结果**：列出上述 4 项的状态（`PASS` / `WARN` / `FAIL`）及关键事实（MCP 工具状态、配置的模型、探针回复、耗时、错误摘要）
- **修改建议**：针对每一项 `FAIL` 或 `WARN` 给出具体、可执行的修复步骤（如确认 `<project>/.agents/plugins/xz-agent-skills` 链接并重跑 `./scripts/install.sh --special-antigravity`、启用插件、在目标机器安装 OpenCode v2、修正 `special/antigravity/agents/skills/main-worker/SKILL.md` 中的模型名或 OpenCode 提供商鉴权、排查 Remote SSH 下 MCP 运行端路径）；全部通过时写“无”。
