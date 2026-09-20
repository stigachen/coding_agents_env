# cc_dev_env — my Claude Code environment

集中管理我的 [Claude Code](https://docs.claude.com/en/docs/claude-code) 环境定制：
clone 到任何新开发机，一条命令（或一句提示词）完成部署。
（仓库曾名 `cc_statusline`，最初只有状态栏，后扩展为完整的环境定制仓库。）

```
Fable 5 (effort:high) | my-project | git:main          ← statusline/
ctx ██████░░░░ 67% | session:3% weekly:9%

📱 "🔔 [my-project@mac-mini] Claude 在等你批准一个操作" ← hooks/
```

## 模块

| 目录 | 内容 | 文档 |
|---|---|---|
| `statusline/` | 两行状态栏：模型/effort/git 分支 + context 进度条 + 订阅配额（同 `/usage`） | [statusline/README.md](statusline/README.md) |
| `hooks/` | 待审批 / 等待输入 / 任务完成时推送 Telegram / Discord / macOS 桌面通知；终端窗口聚焦时自动静音 | [hooks/README.md](hooks/README.md) |
| `install.sh` | 一键部署：合并 `~/.claude/settings.json`，幂等可重复执行 | — |
| `CLAUDE.md` | 让 Claude Code 自己会装：描述部署流程与仓库约定 | — |

## 安装

新机器上两种方式任选：

**方式一：让 Claude Code 自己装（推荐）**

```bash
git clone https://github.com/stigachen/cc_dev_env && cd cc_dev_env && claude
```

然后直接说：

> 帮我把这个目录所有的配置安装到这个电脑上

Claude 会按 `CLAUDE.md` 里的流程执行 `install.sh`、做冒烟验证、并提醒你补齐
IM token 等本机配置。

**方式二：手动**

```bash
bash install.sh
```

两种方式都是幂等的。安装后：

1. 编辑 `~/.claude/notify.env` 填入 Telegram bot token / Discord webhook（IM 通知才会生效）
2. 状态栏的订阅用量默认只显示 Claude Code 自己喂给它的 session/weekly；想额外看按模型的周配额，把 `~/.claude/notify.env` 里的 `STATUSLINE_USAGE_API` 改成 1（会用本机 OAuth token 调未公开的用量接口）。开启后 macOS 若弹出 Keychain 授权，选 **Always Allow**；不授权也会自动回退读 `~/.claude/.credentials.json`
3. 重启 Claude Code，用 `/hooks` 确认 hooks 已注册

**依赖**：`bash` `curl` `git` `jq`（macOS: `brew install jq`；Windows Git Bash:
把 `jq.exe` 放进 PATH）。支持 macOS / Windows (Git Bash) / Linux。

### 设计要点

- **settings 指向仓库内脚本的绝对路径，不拷贝文件。** `git pull` 后定制即生效，
  无需重新安装（仓库移动位置后重跑一次 `install.sh` 即可）。
- **合并而非覆盖。** `install.sh` 用 jq 把配置合并进 `~/.claude/settings.json`，
  只增删本仓库自己的条目，不碰你手工配置的其他 hooks / 设置。
- **密钥不入库。** IM token 等放 `~/.claude/notify.env`（每台机器各自填写），
  仓库里只有 `notify.env.example` 模板。
- **开关全在 notify.env。** 部署一次后，各类通知的启停（待审批 / 等输入 /
  回合结束 / 前台静音 / 桌面弹窗）和状态栏的用量接口开关（`STATUSLINE_USAGE_API`）
  都只改 `~/.claude/notify.env`，即时生效，不用碰 settings.json、不用重装。
  重跑 `install.sh` 会自动补齐模板新增的开关。

## 更新

```bash
git pull   # 脚本改动即刻生效
# 仅当 install.sh 本身或 settings 结构有变化时才需要重跑：
bash install.sh
```

## Roadmap：还能定制什么

Claude Code 几乎所有环境面都可以放进这个仓库统一管理，按需增加子目录 +
`install.sh` 中对应的部署段即可（约定见 `CLAUDE.md`）：

- **`memory/` → `~/.claude/CLAUDE.md`** — 全局记忆/偏好：代码风格、常用回复语言、
  个人约定，所有项目生效
- **`skills/` → `~/.claude/skills/`** — 自定义斜杠命令（skill）：把常用工作流
  （发布检查、周报生成、代码走查清单）做成 `/命令`
- **`agents/` → `~/.claude/agents/`** — 自定义 subagent：预设专用系统提示词和
  工具白名单的子代理
- **`settings/permissions`** — 权限白名单：把常用只读命令加进 allowlist，
  减少审批弹窗（可用内置 `/fewer-permission-prompts` 生成初稿）
- **`keybindings.json` → `~/.claude/keybindings.json`** — 自定义快捷键
- **`mcp/`** — 常用 MCP server 清单（`claude mcp add` 脚本化，或项目级 `.mcp.json`）
- **更多 hooks** — 如 `PreToolUse` 做危险命令拦截、`PostToolUse` 自动 format、
  `SessionStart` 注入上下文

## License

MIT
