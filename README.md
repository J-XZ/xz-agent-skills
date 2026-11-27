# Agent Skills

遵循 [Agent Skills 规范](https://agentskills.io/specification) 的个人编程技能库：

- **标准版**：通用技能，推荐用于 **OpenCode**。
- **特殊版（`--special-antigravity`）**：适用于 **Google Antigravity**，通过插件附带的本地 Stdio MCP 搭配 **Antigravity + OpenCode** 使用。

## 技能

| Skill | 用途 |
| --- | --- |
| [bro](agents/skills/bro/SKILL.md) | 将回复改写为简短自然的表达 |
| [check](agents/skills/check/SKILL.md) | 按需自检 OpenCode、子代理与模型是否可用并给出修复建议 |
| [debug](agents/skills/debug/SKILL.md) | 复现、取证、最小修复及回归验证 |
| [how](agents/skills/how/SKILL.md) | 只读解释代码、调用链和数据流 |
| [why](agents/skills/why/SKILL.md) | 调查设计缘由和历史约束 |
| [labsafe](agents/skills/labsafe/SKILL.md) | 学校实验平台的强制操作规则 |
| [main-worker](agents/skills/main-worker/SKILL.md) | 主代理核心规则、成本分层调度、独立审核及验收 |
| [perf-evidence](agents/skills/perf-evidence/SKILL.md) | 性能假设、实测及优化收益验证 |
| [show-me-your-work](agents/skills/show-me-your-work/SKILL.md) | 记录关键决策及证据 |
| [work-rules](agents/skills/work-rules/SKILL.md) | 范围、代码与文档风格、验证及用户工作保护 |

## 安装

适用于 Linux、macOS 与 WSL，需要 Bash 及符号链接支持；`--special-antigravity` 额外需要 Python 3。

```bash
# 1. 标准版（推荐用于 OpenCode）
./scripts/install.sh --link /path/to/project/.agents/skills

# 2. Antigravity 特殊版（生成插件并自动链接到 <project>/.agents/plugins/xz-agent-skills）
./scripts/install.sh --special-antigravity --link /path/to/project/.agents/skills

# 3. 远程安装：在命令末尾附加 USER HOST，通过 SSH 在远程执行全部安装与链接
./scripts/install.sh --special-antigravity --link /remote/project/.agents/skills user host
```

说明：

- **安装位置**（遵循 `XDG_DATA_HOME`，默认 `~/.local/share`）：
  - 标准版：`~/.local/share/xz-agent-skills/.agents/skills/`
  - 特殊版：`~/.local/share/xz-agent-skills/special/antigravity/.agents/plugins/xz-agent-skills/`
- **`--link` 规则**：可重复传入，必须指向已存在项目下的 `<project>/.agents/skills`。特殊版不会写入 `.agents/skills`，而是自动链接到同级 `<project>/.agents/plugins/xz-agent-skills`。
- **更新与切换**：重复执行会自动覆盖全局目录中的旧版本技能和 `--link` 处的旧符号链接；在同一项目切换标准版与特殊版时，自动移除另一版本遗留的受管链接（保留用户自定义技能）；完整参数见 `./scripts/install.sh --help`。

## 配置子代理模型

标准版与特殊版的模型配置位置不同（模型格式均为 `provider/model#variant`，需先在 OpenCode 中配置对应提供商权限）：

### 1. 标准版：在 OpenCode 配置文件中设置

编辑 `~/.config/opencode/opencode.jsonc`，定义 `worker`（廉价执行者）和 `reviewer`（中档只读审核者）：

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

### 2. Antigravity 特殊版：在技能文本中设置

直接编辑 [special/antigravity/agents/skills/main-worker/SKILL.md](special/antigravity/agents/skills/main-worker/SKILL.md) 中「**OpenCode MCP 委派**」一节的默认模型表（设置执行者与审核者的 `provider/model#variant`），修改后重新运行 `./scripts/install.sh --special-antigravity` 生效。

调用 MCP 时模型未填写或配置无效会直接报错。

## 结构与校验

```text
agents/skills/<skill-name>/SKILL.md            # 标准版技能
special/antigravity/                           # Antigravity 插件源码（plugin.json、mcp/、覆盖技能）
scripts/install.sh                             # 本地 / SSH 远程安装脚本
```

校验所有技能 Frontmatter：

```bash
for skill in agents/skills/* special/antigravity/agents/skills/*; do
  skills-ref validate "$skill"
done
```
