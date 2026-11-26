# Agent Skills

个人编程技能库，遵循 [Agent Skills 规范](https://agentskills.io/specification)。使用 `SKILL.md`、YAML Frontmatter 和 Markdown 定义技能，可附带脚本、参考文档和资源，不依赖特定编程软件、模型或工具接口。

## 技能

| Skill | 用途 |
| --- | --- |
| [bro](agents/skills/bro/SKILL.md) | 将回复改写为简短自然的表达 |
| [debug](agents/skills/debug/SKILL.md) | 复现、取证、最小修复及回归验证 |
| [how](agents/skills/how/SKILL.md) | 只读解释代码、调用链和数据流 |
| [why](agents/skills/why/SKILL.md) | 调查设计缘由和历史约束 |
| [labsafe](agents/skills/labsafe/SKILL.md) | 学校实验平台的强制操作规则 |
| [main-worker](agents/skills/main-worker/SKILL.md) | 主代理核心规则、成本分层调度、独立审核及验收 |
| [perf-evidence](agents/skills/perf-evidence/SKILL.md) | 性能假设、实测及优化收益验证 |
| [show-me-your-work](agents/skills/show-me-your-work/SKILL.md) | 记录关键决策及证据 |
| [work-rules](agents/skills/work-rules/SKILL.md) | 范围、代码与文档风格、验证及用户工作保护 |

## 安装

需要 Bash、常见 Unix 文件工具及符号链接支持；适用于 Linux、macOS，Windows 可在 WSL 内运行。脚本无需网络，不安装依赖，不修改任何客户端配置。

在本仓库执行：

```bash
./scripts/install.sh
```

默认复制到 `${XDG_DATA_HOME:-$HOME/.local/share}/xz-agent-skills/.agents/skills/`。重复执行会跳过相同内容，替换已变更的技能，并移除源码中已删除的技能及其在本次 `--link` 目录中的链接；只处理本脚本安装的技能。安装目录视为生成内容，请在本仓库修改后重新安装。

可自定义安装根目录，并同时链接到一个或多个技能目录：

```bash
./scripts/install.sh --prefix "$HOME/.local/share/xz-agent-skills" \
  --link /path/to/project/.agents/skills

# Cursor 使用专属目录时
./scripts/install.sh --link /path/to/project/.cursor/skills

./scripts/install.sh --help
```

`--link` 接收技能目录本身，支持重复传入。脚本自动创建目录，保留已指向本次安装的链接；遇到其他已有目录、文件或链接会报错，不覆盖。安装以每个技能为单位替换，失败时可能已完成部分技能，请修正原因后重跑；不保证整批事务回滚。

### Antigravity 特殊版

```bash
./scripts/install.sh --special-antigravity --link /path/to/antigravity/skills
```

将 `--link` 后的示例路径替换为宿主的技能目录。脚本安装全部通用技能，再在暂存目录内合入 `special/antigravity/agents/skills/` 中的差异，默认安装根目录为 `${XDG_DATA_HOME:-$HOME/.local/share}/xz-agent-skills/special/antigravity`。两版可使用不同的链接目录并存。显式传入相同的 `--prefix` 会切换该安装及其已有链接使用的版本。

Antigravity 通过终端运行 OpenCode v2。请在特殊版 [main-worker](special/antigravity/agents/skills/main-worker/SKILL.md) 的「OpenCode 终端委派」区域设置执行者、审核者的 `provider/model#variant`，并在 OpenCode 中配置对应提供商的访问权限。改动源文件后重新安装即可。

## 在不同客户端使用

| 客户端 | 项目技能目录示例 |
| --- | --- |
| Codex | `.agents/skills/` |
| OpenCode | `.agents/skills/`、`.opencode/skills/` |
| Claude Code | `.claude/skills/` |
| Cursor | `.cursor/skills/` |
| 其他支持 Agent Skills 的客户端 | 按客户端文档选择技能搜索目录 |

各客户端版本支持的发现路径、符号链接和多代理能力可能不同，以其文档为准。若客户端不跟随符号链接，复制完整技能目录。

通用版的 `main-worker` 和 `perf-evidence` 需要宿主支持子代理及独立审核上下文；不支持时立即报错并交还用户。各技能通过名称互相引用。

主代理使用 `main-worker`，其中包含所有代理必须遵守的核心规则。多代理按成本分层：主代理最贵，负责拆解任务、指导、裁决和验收；执行者最便宜，按小步骤完成实现、实验和测试；审核者居中。

## 配置子代理模型

通用版由客户端配置模型。`main-worker` 把执行者派给名为 `worker` 的子代理，审核者派给 `reviewer`；在客户端的用户级配置中定义这两个代理并指定模型，所有项目通用。未指定模型的子代理沿用主代理的模型，成本分层不生效。

下文 `<cheap-model>` 替换为执行者使用的最便宜且胜任的模型，`<mid-model>` 替换为审核者使用的中档模型。

### OpenCode

在 `~/.config/opencode/opencode.jsonc` 中添加，模型格式为 `provider/model#variant`，保存即生效：

```jsonc
"agents": {
  "worker": {
    "description": "执行者：按 main-worker 交接单完成单个步骤",
    "mode": "subagent",
    "model": "<cheap-model>"
  },
  "reviewer": {
    "description": "审核者：只读核查改动、证据和结论",
    "mode": "subagent",
    "model": "<mid-model>",
    "permissions": [
      { "action": "edit", "resource": "*", "effect": "deny" }
    ]
  }
}
```

### Claude Code

每个代理一个文件，`model` 可用 `haiku`、`sonnet`、`opus` 或完整模型 ID；`skills` 让子代理启动时预加载技能。在会话中运行 `/tasks` 查看子代理实际使用的模型。

```markdown
<!-- ~/.claude/agents/worker.md -->
---
name: worker
description: 执行者：按 main-worker 交接单完成单个步骤
model: <cheap-model>
skills: [work-rules]
---

按交接单执行，按 main-worker 的执行者格式回报。
```

```markdown
<!-- ~/.claude/agents/reviewer.md -->
---
name: reviewer
description: 审核者：只读核查改动、证据和结论
model: <mid-model>
disallowedTools: Write, Edit
skills: [work-rules]
---

只审核，按 main-worker 的审核格式回报。
```

### Codex

每个代理一个 TOML 文件，`name`、`description`、`developer_instructions` 必填。`worker` 会覆盖同名内置代理。

```toml
# ~/.codex/agents/worker.toml
name = "worker"
description = "执行者：按 main-worker 交接单完成单个步骤"
model = "<cheap-model>"
model_reasoning_effort = "medium"
developer_instructions = "加载 work-rules，按交接单执行，按 main-worker 的执行者格式回报。"
```

```toml
# ~/.codex/agents/reviewer.toml
name = "reviewer"
description = "审核者：只读核查改动、证据和结论"
model = "<mid-model>"
model_reasoning_effort = "high"
developer_instructions = "加载 work-rules，只审核不修改文件，按 main-worker 的审核格式回报。"
```

在 `~/.codex/config.toml` 中设置子代理默认模型，并显式登记代理文件：

```toml
[agents]
default_subagent_model = "<cheap-model>"

[agents.worker]
config_file = "/home/<user>/.codex/agents/worker.toml"

[agents.reviewer]
config_file = "/home/<user>/.codex/agents/reviewer.toml"
```

Codex 子代理继承主会话的权限和沙箱，审核者的只读由指令约束。部分 Codex 版本派发子代理时不应用代理文件中的模型，子代理会使用默认模型或主代理的模型；配置后在会话日志中核对子代理实际使用的模型。

### Cursor

每个代理一个文件，`model` 填模型 ID，可用 `[effort=high]` 等参数；`readonly: true` 禁止写文件和改变状态的命令。

```markdown
<!-- ~/.cursor/agents/worker.md -->
---
name: worker
description: 执行者：按 main-worker 交接单完成单个步骤
model: <cheap-model>
---

加载 work-rules，按交接单执行，按 main-worker 的执行者格式回报。
```

```markdown
<!-- ~/.cursor/agents/reviewer.md -->
---
name: reviewer
description: 审核者：只读核查改动、证据和结论
model: <mid-model>
readonly: true
---

加载 work-rules，只审核，按 main-worker 的审核格式回报。
```

团队管理员屏蔽该模型、套餐不包含该模型，或旧版按请求计费套餐未开启 Max Mode 时，Cursor 会改用其他模型；子代理任务卡片显示实际使用的模型。

## 维护

```text
agents/skills/<skill-name>/
├── SKILL.md
├── scripts/       # 可选：执行脚本
├── references/    # 可选：按需阅读的文档
└── assets/        # 可选：模板及其他资源
scripts/install.sh
```

`SKILL.md` 以 YAML Frontmatter 声明 `name` 和 `description`，正文写步骤、边界及交付要求。`name` 与目录名一致，使用小写字母、数字和单连字符，不超过 64 个字符；安装脚本会校验这一点。`description` 是代理决定是否加载技能的唯一依据，先用一句话说明做什么，再写何时使用，并带上用户可能说出的关键词。

按需引用的资源使用相对技能根目录的路径。模型、工具和调用参数使用宿主实际提供的能力。技能正文遵循 `work-rules` 的文档风格。

如已安装官方参考工具，可逐项校验：

```bash
for skill in agents/skills/*; do
  skills-ref validate "$skill"
done
```
