# coding_agents_env — my coding agent environments

集中管理我对各个 coding agent 的环境定制——[Claude Code](https://docs.claude.com/en/docs/claude-code)、
[Codex](https://developers.openai.com/codex)、[OpenCode](https://opencode.ai)——
clone 到任何新开发机，一条命令（或一句提示词）完成部署。
（仓库曾名 `cc_statusline`，最初只有 Claude Code 状态栏；后扩展为 `cc_dev_env`；
接入 Codex / OpenCode 后改为现名。）

```
Fable 5 (effort:high) | my-project | git:main          ← claude/statusline/
ctx ██████░░░░ 67% | session:3% weekly:9%

📱 "🔔 [my-project@mac-mini] Claude 在等你批准一个操作" ← lib/send.sh
📱 "✅ [my-project@mac-mini] Codex 任务完成"
```

## 模块

| 目录 | 内容 | 文档 |
|---|---|---|
| `lib/` | 三家共用的通知内核：待审批 / 等待输入 / 任务完成时推送 Telegram / Discord / macOS 桌面通知；终端窗口聚焦时自动静音；所有开关在一个本机文件里，支持按 agent 覆盖 | [lib/README.md](lib/README.md) |
| `claude/` | Claude Code：两行状态栏（模型/effort/git 分支 + context 进度条 + 订阅配额）、Notification/Stop hooks 适配层、settings.json 合并 | [statusline](claude/statusline/README.md) · [hooks](claude/hooks/README.md) |
| `codex/` | Codex CLI：hooks.json 通知适配（含 hook 信任 hash 的自动写入）、`[tui] status_line` 配置片段 | [codex/README.md](codex/README.md) |
| `opencode/` | OpenCode：通知插件 | — |
| `install.sh` | 一键部署：共用配置生成/迁移，再按本机装了哪些 agent 分发到各目录，幂等可重复执行 | — |
| `AGENTS.md` | 让 agent 自己会装：描述部署流程与仓库约定（三家都读；`CLAUDE.md` 仅一行 `@AGENTS.md`） | — |

## 安装

新机器上两种方式任选：

**方式一：让 agent 自己装（推荐）**

```bash
git clone https://github.com/stigachen/coding_agents_env && cd coding_agents_env && claude   # 或 codex / opencode
```

然后直接说：

> 帮我把这个目录所有的配置安装到这个电脑上

agent 会按 `AGENTS.md` 里的流程执行 `install.sh`、做冒烟验证、并在对话里
收集 IM token 等本机配置。

**方式二：手动**

```bash
bash install.sh            # 自动检测本机装了哪些 agent
bash install.sh claude     # 只装指定的
```

两种方式都是幂等的。安装后：

1. 编辑 `~/.config/coding_agents_env/notify.env` 填入 Telegram bot token /
   Discord webhook（IM 通知才会生效）。这一个文件三家共用
2. Claude Code 状态栏的订阅用量默认只显示 Claude Code 自己喂给它的 session/weekly；
   想额外看按模型的周配额，把 `notify.env` 里的 `CLAUDE_STATUSLINE_USAGE_API`
   改成 1（会用本机 OAuth token 调未公开的用量接口）。开启后 macOS 若弹出
   Keychain 授权，选 **Always Allow**；不授权也会自动回退读 `~/.claude/.credentials.json`
3. 重启各 agent 会话；Claude Code 用 `/hooks` 确认 hooks 已注册

**依赖**：`bash` `curl` `git` `jq`（macOS: `brew install jq`；Windows Git Bash:
把 `jq.exe` 放进 PATH）。支持 macOS / Windows (Git Bash) / Linux。

### 从旧版（cc_dev_env）升级

老机器 `git pull` 后重跑一次 `bash install.sh`（或让 Claude Code 按 AGENTS.md
重新部署）即可：旧路径的 settings 条目会被替换，`~/.claude/notify.env` 自动
搬到 `~/.config/coding_agents_env/notify.env`（旧路径留软链），token 和已改的
开关原样保留，不用重填。pull 到重跑之间状态栏和通知会暂时失效，属预期。

### 设计要点

- **配置指向仓库内脚本的绝对路径，不拷贝文件。** `git pull` 后定制即生效，
  无需重新安装（仓库移动位置后重跑一次 `install.sh` 即可）。
- **合并而非覆盖，不动第三方配置。** `install.sh` 只增删本仓库自己的条目，
  机器上其他工具写入的 hooks / 插件 / 设置一律保留。
- **密钥不入库。** IM token 等放 `~/.config/coding_agents_env/notify.env`
  （每台机器各自填写），仓库里只有 `lib/notify.env.example` 模板。
- **开关全在 notify.env，三家共用。** 部署一次后，各类通知的启停（待审批 /
  等输入 / 回合结束 / 前台静音 / 桌面弹窗）和状态栏的用量接口开关都只改这一个
  文件，即时生效，不用碰各 agent 的配置、不用重装。需要区别对待某个 agent 时
  加前缀（`CODEX_NOTIFY_ON_STOP=0`）。重跑 `install.sh` 会自动补齐模板新增的开关。
- **适配层薄，内核厚。** 每个 agent 目录只把自家事件格式翻译成 `lib/send.sh`
  的调用，措辞、静音、推送逻辑只有一份。

## 更新

```bash
git pull   # 脚本改动即刻生效
# 仅当 install.sh 本身或各 agent 配置结构有变化时才需要重跑：
bash install.sh
```

## Roadmap：还能定制什么

各 agent 几乎所有环境面都可以放进这个仓库统一管理，按需在对应 agent 目录下
增加模块 + `install.sh` 中对应的部署段即可（约定见 `AGENTS.md`）：

- **全局记忆/偏好** — `~/.claude/CLAUDE.md`、`~/.codex/AGENTS.md`：代码风格、
  常用回复语言、个人约定，所有项目生效
- **skills / 自定义命令** — `~/.claude/skills/`、`~/.codex/skills/`
- **agents / subagent 定义**
- **权限白名单** — 常用只读命令加进 allowlist，减少审批弹窗
- **keybindings** — `~/.claude/keybindings.json`、OpenCode `tui.json`
- **MCP server 清单** — 脚本化 `claude mcp add` / Codex `mcp_servers` / OpenCode `mcp`
- **更多 hooks** — 如 `PreToolUse` 做危险命令拦截、`PostToolUse` 自动 format、
  `SessionStart` 注入上下文

## License

MIT
