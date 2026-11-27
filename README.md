# Agent Skills

个人编程技能库，遵循 [Agent Skills 规范](https://agentskills.io/specification)。

- **标准版技能**是通用的，推荐用于 **OpenCode**。
- **特殊版（`--special-antigravity`）**目前适用于 **Google Antigravity**，以插件和本地 Stdio MCP 方式搭配 **Antigravity + OpenCode** 使用。

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

需要 Bash、常见 Unix 文件工具及符号链接支持；`--special-antigravity` 额外需要 Python 3。适用于 Linux、macOS，Windows 可在 WSL 内运行。脚本无需网络，不安装第三方依赖，不修改任何客户端全局配置。

### 标准版（推荐用于 OpenCode）

在本仓库执行：

```bash
./scripts/install.sh
```

默认复制到 `${XDG_DATA_HOME:-$HOME/.local/share}/xz-agent-skills/.agents/skills/`。重复执行会跳过相同内容、覆盖旧版本技能，并移除源码中已删除的技能及其在本次 `--link` 目录中的链接。安装目录视为生成内容，请在本仓库修改后重新安装。

可同时链接到一个或多个项目的 `.agents/skills` 目录，也支持在命令末尾附加 `USER HOST` 通过 SSH 在远程主机执行全部安装和链接操作：

```bash
./scripts/install.sh --link /path/to/project/.agents/skills

# 远程安装到 user@host（全局目录和 --link 均在远程执行）
./scripts/install.sh --link /remote/project/.agents/skills user host

./scripts/install.sh --help
```

`--link` 必须指向已存在项目下的 `<project>/.agents/skills` 目录（路径格式不符或 `<project>` 不存在时脚本直接报错），支持重复传入。目标处已存在旧符号链接会自动覆盖；遇到非符号链接的真实文件或目录则报错，不覆盖。

### Antigravity 特殊版（搭配 Antigravity + OpenCode）

```bash
./scripts/install.sh --special-antigravity --link /path/to/project/.agents/skills

# 远程安装 Antigravity 插件
./scripts/install.sh --special-antigravity --link /remote/project/.agents/skills user host
```

传入 `--special-antigravity` 时，脚本将全部通用技能与 `special/antigravity/` 合并生成完整的 Antigravity 插件（含 `plugin.json`、`mcp_config.json`、Stdio MCP 服务及全部技能），安装到 `${XDG_DATA_HOME:-$HOME/.local/share}/xz-agent-skills/special/antigravity/.agents/plugins/xz-agent-skills`。传给 `--link` 的路径仍须校验为已存在项目下的 `<project>/.agents/skills`，但脚本**不会**向该目录安装内容，而是自动将插件链接到同级 `<project>/.agents/plugins/xz-agent-skills`。两版可各自维护、互不冲突。

Antigravity 通过插件附带的 `xz-agent-skills-opencode` Stdio MCP 服务在终端沙箱外调用 OpenCode v2（无需关闭终端沙箱或逐次审批命令行）。请在特殊版 [main-worker](special/antigravity/agents/skills/main-worker/SKILL.md) 中设置执行者、审核者的 `provider/model#variant`，并在 OpenCode 中配置对应提供商的访问权限；调用时未传模型或模型无效会直接报错。改动源文件后重新安装即可。

## 在 OpenCode 中配置子代理模型（标准版）

标准版的 `main-worker` 和 `perf-evidence` 将执行者派给子代理 `worker`，审核者派给 `reviewer`。在 `~/.config/opencode/opencode.jsonc` 中定义这两个代理并指定模型（格式为 `provider/model#variant`），保存即生效；未指定模型的子代理沿用主代理模型，成本分层不生效。

将下文 `<cheap-model>` 替换为执行者使用的最便宜且胜任的模型，`<mid-model>` 替换为审核者使用的中档模型：

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

## 维护

```text
agents/skills/<skill-name>/
├── SKILL.md
├── scripts/       # 可选：执行脚本
├── references/    # 可选：按需阅读的文档
└── assets/        # 可选：模板及其他资源
special/antigravity/
├── plugin.json
├── mcp/opencode_mcp.py
└── agents/skills/<skill-name>/
    └── SKILL.md
scripts/install.sh
```

`SKILL.md` 以 YAML Frontmatter 声明 `name` 和 `description`，正文写步骤、边界及交付要求。`name` 与目录名一致，使用小写字母、数字和单连字符，不超过 64 个字符；安装脚本会校验这一点。`description` 是代理决定是否加载技能的唯一依据，先用一句话说明做什么，再写何时使用，并带上用户可能说出的关键词。

按需引用的资源使用相对技能根目录的路径。技能正文遵循 `work-rules` 的文档风格。

如已安装官方参考工具，可逐项校验：

```bash
for skill in agents/skills/* special/antigravity/agents/skills/*; do
  skills-ref validate "$skill"
done
```
