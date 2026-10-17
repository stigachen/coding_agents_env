# coding_agents_env — coding agent 环境定制仓库

这个仓库集中管理我个人对各个 coding agent（Claude Code / Codex / OpenCode / Grok CLI）的
环境定制：状态栏、通知 hooks 等。目标是在任何新开发机上 clone 下来即可一键部署。
本文件供各 agent 读取（`CLAUDE.md` 只是 `@AGENTS.md`
一行引入，给不支持直接读 AGENTS.md 的旧版 Claude Code 用）。

## 自动部署（重要）

当用户要求"把这个目录的配置安装到这台电脑"、"部署这些定制"、"install/setup
这个仓库"、"重新部署"、"升级到新版"或任何同义表述时，执行以下流程：

1. 运行 `bash install.sh`（幂等，可放心重复执行；脚本本身非交互——它由
   agent 的 shell 工具执行，stdin 不是 TTY，任何交互都放在下面第 2 步由对话完成）。
   它会：
   - 生成 / 迁移 / 补齐各 agent 共用的本机配置 `~/.config/coding_agents_env/notify.env`
     （chmod 600）。旧版仓库把它放在 `~/.claude/notify.env`，检测到即自动搬到
     新位置、旧路径留软链，token 原样保留；模板新增的开关自动补齐，改过名的
     键用旧值生成新键
   - 检测本机装了哪些 agent（看 `~/.claude` `~/.codex` `~/.config/opencode`
     `${GROK_HOME:-$HOME/.grok}` 或 PATH），逐个执行 `<agent>/install.sh`。也可指定：
     `bash install.sh claude` 或 `bash install.sh grok`
   - Claude Code：在 `~/.claude/settings.json` 写入 statusLine 配置和
     Notification/Stop hooks，命令指向本仓库内脚本的绝对路径（git pull 即生效，
     不拷贝文件）。旧版仓库布局写入的条目会被识别并替换
   - OpenCode：在 `~/.config/opencode/plugins/` 生成转发文件 `coding_agents_env.ts`
     （一行 export 指向仓库里的 `opencode/notify.ts`），其他插件不动
   - Codex：在 `~/.codex/hooks.json` 注册 Stop/PermissionRequest hooks；在
     `~/.codex/config.toml` 写入这两个 hook 的信任 hash（Codex 只执行已信任的
     hook）、`[features] hooks = true`、`[tui]` 状态栏项（改写前备份为
     `config.toml.bak`）
   - Grok CLI：在 `${GROK_HOME:-$HOME/.grok}/hooks/coding_agents_env.json` 注册
     Stop / Notification hooks，直接指向仓库的 `grok/hooks/notify.sh`，无需 Claude。
     同时在 `config.toml` 写入 `[ui.status_line]` 的 `type` 和 `command`，指向
     `grok/statusline/statusline.sh`；其他表和键保留。无法安全改写时保留原文件并失败。
     软链改目标，成功改写前备份为 `config.toml.bak`。不修改 Grok 的 `[compat.claude]`、第三方 hooks 或 Claude
     配置。Grok 默认仍合并 Claude 兼容 hooks，本仓库的 Claude 入口一律跳过 Grok
     事件，无论原生 hooks 是否已安装；从旧实现升级需要运行 `bash install.sh grok`。
     通知使用标准 `GROK_NOTIFY_ON_STOP` / `GROK_NOTIFY_ON_PERMISSION` /
     `GROK_NOTIFY_ON_IDLE` 覆盖公共 `NOTIFY_ON_*`，没有额外总开关。状态栏表在
     下次启动 Grok 时加载
2. **交互式收集通知渠道配置**。检查 `~/.config/coding_agents_env/notify.env`：
   若没有任何渠道键填了值，在对话中询问用户。判断命令（有输出即视为已配置，
   通用键和 `CLAUDE_` / `CODEX_` / `OPENCODE_` / `GROK_` 前缀键都算）：
   `grep -E '^([A-Z]+_)?(TELEGRAM_BOT_TOKEN|DISCORD_WEBHOOK_URL)=.+' ~/.config/coding_agents_env/notify.env`
   - 用哪个通知渠道？（Telegram / Discord / 两者 / 暂不配置）
   - 对应的凭据：Telegram 要 bot token + chat_id（用户没有的话，指引：找
     @BotFather 建 bot；给 bot 发条消息后访问
     `https://api.telegram.org/bot<TOKEN>/getUpdates` 查 chat_id）；
     Discord 要 webhook URL（服务器设置 → 整合 → Webhook）
   - 是否开启回合结束通知（NOTIFY_ON_STOP，默认 1）和 macOS 桌面弹窗（DESKTOP_NOTIFY）。
     其余开关（NOTIFY_ON_PERMISSION / NOTIFY_ON_IDLE / 前台静音等，全表见
     lib/README.md）默认值即合理，不要逐一询问；告知用户以后随时改
     `~/.config/coding_agents_env/notify.env` 即可，即时生效
   把用户的回答写入该文件（保持 KEY=VALUE 格式，chmod 600）。
   用户选"暂不配置"则跳过，不要反复追问。已经填过（从旧版迁移来的）就不问。
   凭据处理纪律：token 只写入该文件，不回显完整值、不写进仓库任何文件、
   不出现在 git 提交中。
3. 验证（只检查本次实际安装的 agent）：
   - 装了 Claude Code 的机器，状态栏冒烟测试：
     `echo '{"model":{"display_name":"Test"},"workspace":{"current_dir":"'$HOME'"},"context_window":{"used_percentage":42}}' | bash claude/statusline/statusline.sh`
   - 装了 Claude Code 的机器，检查 `~/.claude/settings.json` 合并结果为合法 JSON，且条目指向
     `claude/` 下的新路径、没有残留旧路径：
     `jq '[.statusLine.command, (.hooks[][].hooks[].command)] | map(select(test("cc_dev_env|coding_agents_env")))' ~/.claude/settings.json`
   - Claude Code 通知链路 dry-run（不真发）：
     `echo '{"hook_event_name":"Stop","last_assistant_message":"测试","cwd":"'$PWD'"}' | NOTIFY_DRY_RUN=1 bash claude/hooks/notify.sh`
   - 装了 Claude Code 且第 2 步配置了 IM 渠道（或已有渠道）时，发一条测试通知让用户
     在手机上确认收到：
     `echo '{"hook_event_name":"Notification","notification_type":"permission_prompt","cwd":"'$PWD'"}' | bash claude/hooks/notify.sh`
     注意前台静音：终端窗口聚焦时不会真发，可临时 `NOTIFY_SKIP_WHEN_FOCUSED=0`
     加在命令前
   - 装了 Codex 的机器：`jq . ~/.codex/hooks.json` 合法且含本仓库的
     Stop/PermissionRequest 条目；`grep -c coding_agents_env ~/.codex/config.toml`
     ≥ 2（状态栏两行）；`grep -A1 'hooks.json:stop' ~/.codex/config.toml` 能看到
     trusted_hash。可跑一轮 `codex exec "Reply with exactly the single word: pong"`
     端到端验证（会真发一条 Codex 任务完成通知）
   - 装了 OpenCode 的机器：`~/.config/opencode/plugins/coding_agents_env.ts` 存在且
     指向仓库路径。端到端：`NOTIFY_DEBUG=1 opencode run --standalone "Reply with
     exactly the single word: pong"` 后 `~/.claude/notify-debug.log` 应有
     `agent=OpenCode kind=stop` 一行
   - 装了 Grok 的机器：`jq . "${GROK_HOME:-$HOME/.grok}/hooks/coding_agents_env.json"`
     合法且含指向本仓库 `grok/hooks/notify.sh` 的 Stop / Notification 条目。
     `grep grok/statusline/statusline.sh "${GROK_HOME:-$HOME/.grok}/config.toml"`
     能看到状态栏命令。状态栏冒烟：
     `echo '{"model":{"display_name":"Test"},"effort":{"level":"high"},"workspace":{"current_dir":"'$HOME'","branch":"main"},"context_window":{"used_percentage":42},"cost":{"total_cost_usd":1.23}}' | bash grok/statusline/statusline.sh`
     按 `grok/README.md` 的隔离 dry-run 检查 `end_turn`、`permission_prompt`、
     `idle_prompt`，包括子 agent 待审批仍通知、子 agent Stop / idle 和退出会话
     不通知；不必真发或改本机通知开关。状态栏配置要重启 Grok 才加载
4. 提醒用户：
   - 状态栏用量默认只显示 Claude Code 喂给 stdin 的 session/weekly；想看按模型的
     周配额需把 `notify.env` 的 `CLAUDE_STATUSLINE_USAGE_API` 设 1（用本机 OAuth
     token 调未公开接口，默认关闭，不要替用户打开）。开启后 macOS 若弹 Keychain
     授权选 "Always Allow"，不授权时脚本自动回退读 `~/.claude/.credentials.json`
   - 重启各 agent 会话；Claude Code 用 `/hooks` 确认 hooks 已注册

依赖：`bash` `curl` `git` `jq`。缺 `jq` 时 macOS 用 `brew install jq`，
Windows Git Bash 把 `jq.exe` 放进 PATH。

### 从旧版（cc_dev_env 布局）升级

老机器上 `git pull` 之后状态栏和 hook 会暂时失效（settings.json 里还是
`statusline/` `hooks/` 的旧路径），这是预期的。按上面的流程重新部署一次即可：
`install.sh` 会替换掉旧路径条目、迁移 `notify.env`。验证时重点看第 3 步的
jq 检查没有旧路径残留，以及 `~/.config/coding_agents_env/notify.env` 里 token
还在。不需要用户重填任何东西。

## 仓库结构

- `install.sh` — 一键部署入口：共用配置的生成/迁移，再按检测到的 agent 分发到
  各目录的 `install.sh`
- `lib/` — 各 agent 共用的部分：
  - `send.sh` 通知内核：读 `notify.env`、按事件类型和 agent 判开关、拼消息
    （前缀带主机名，多机共用渠道时区分来源）、前台静音（终端窗口有键盘焦点时
    不推）、推送 Telegram / Discord / macOS 桌面通知。接口
    `send.sh <kind> <project> <agent>`，正文走 stdin；`NOTIFY_DRY_RUN=1` 只打印不发
  - `focus_check.ps1` Windows 前台检测端
  - `notify.env.example` 共用配置模板
- `claude/` — Claude Code：
  - `statusline/` 两行状态栏：模型/effort/git 分支 + context 进度条 + 订阅配额
    （session/weekly 取自 Claude Code 喂给 stdin 的 `rate_limits`；按模型周配额
    走未公开接口，由 `notify.env` 的 `CLAUDE_STATUSLINE_USAGE_API` 控制，默认关）
  - `hooks/notify.sh` Notification / Stop 事件的适配层：把 Claude 的事件 JSON
    翻译成 `send.sh` 的参数。检测到非空 `GROK_HOOK_EVENT` 时直接退出，
    不检测原生 hooks 是否已安装；Grok 只走自己的原生入口，避免重复通知
  - `install.sh` 合并 `~/.claude/settings.json`
- `codex/` — Codex CLI：
  - `hooks/notify.sh` Stop / PermissionRequest 事件的适配层（Codex 没有 idle 事件）
  - `tui.toml` 写进 `[tui]` 表的状态栏行（Codex 只支持内置项目，不支持自定义命令）
  - `install.sh` 合并 hooks.json、按 Codex 算法写入 hook 信任 hash、插入 `[tui]` 行。
    细节见 codex/README.md
- `opencode/` — OpenCode：
  - `notify.ts` 通知插件（v1/v2 两代插件 API 都支持；回合结束 / 等审批 / 执行失败）
  - `install.sh` 在 OpenCode 插件目录生成一行转发文件指向仓库。OpenCode 没有可
    配置的状态栏。细节见 opencode/README.md
- `grok/` — Grok CLI：
  - `statusline/statusline.sh` 两行状态栏：模型/effort/目录/git 分支（链接
    worktree 带名字）+ context 进度条 + 本会话费用。不读配额、不调用 git
  - `hooks/notify.sh` 原生适配层：主会话 `Stop` 仅接受 `reason=end_turn`，
    Notification 只接收 `permission_prompt` / `idle_prompt`；子 agent 待审批
    仍通知，只忽略其 Stop / idle。忽略会话退出、`task_complete` 和未知类型；
    不依赖 Claude Code
  - `install.sh` 在 Grok 全局 hooks 目录注册本仓库条目，并合并
    `[ui.status_line]` 的 `type` / `command`。开关和渠道由 `lib/send.sh`
    统一处理；Grok 调试日志写入共用配置目录下的 `notify-debug.log`。
    Stop gate 的重复触发限制及隔离测试见 grok/README.md

## 约定

- **不动第三方配置。** 任何机器上，`install.sh` 只增删本仓库自己的条目（按脚本
  路径特征识别：`/hooks/notify.sh` 等），机器上已有的其他工具写入的 hooks、
  插件、配置键一律保留。合并而非覆盖
- 所有 `*.sh` 必须 LF 结尾、兼容 bash 3.2（macOS 自带）与 Git Bash（Windows），
  多字节字符输出用 printf 八进制转义；变量后面紧跟中文标点时要写成 `${var}`
  （bash 3.2 会把多字节字符的首字节并进变量名）
- 密钥（IM token 等）一律放 `~/.config/coding_agents_env/notify.env` 这类机器
  本地文件，绝不进仓库
- 通知行为和状态栏的开关一律加在 `notify.env`（由 `send.sh` / 各 agent 脚本
  运行时读取、带默认值），agent 专属的键加 `CLAUDE_` / `CODEX_` / `OPENCODE_` / `GROK_`
  前缀；任何 `NOTIFY_*` 开关都支持加前缀只对某个 agent 生效。不要做进各 agent
  配置文件的 matcher——保证部署一次后调开关只改 notify.env、即时生效，
  不需要重装或重启
- 各 agent 目录的适配层只做"自家事件格式 → send.sh 参数"的翻译，开关、措辞、
  静音、推送不要复制到适配层里
- 新增 agent 时：建顶层目录，带自己的 `install.sh`（幂等，只动自己的条目），
  在根 `install.sh` 的检测列表里加一行，同步更新本文件和 README.md。新增
  定制模块时同理放进对应 agent 目录
