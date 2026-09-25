# coding_agents_env — coding agent 环境定制仓库

这个仓库集中管理我个人对各个 coding agent（Claude Code / Codex / OpenCode）的
环境定制：状态栏、通知 hooks 等。目标是在任何新开发机上 clone 下来即可一键部署。
本文件同时被 Claude Code、Codex、OpenCode 读取（`CLAUDE.md` 只是 `@AGENTS.md`
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
     或 PATH），逐个执行 `<agent>/install.sh`。也可指定：`bash install.sh claude`
   - Claude Code：在 `~/.claude/settings.json` 写入 statusLine 配置和
     Notification/Stop hooks，命令指向本仓库内脚本的绝对路径（git pull 即生效，
     不拷贝文件）。旧版仓库布局写入的条目会被识别并替换
2. **交互式收集通知渠道配置**。检查 `~/.config/coding_agents_env/notify.env`：
   若关键项均为空（TELEGRAM_BOT_TOKEN / DISCORD_WEBHOOK_URL 都没填），在对话中
   询问用户：
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
3. 验证：
   - 状态栏冒烟测试：
     `echo '{"model":{"display_name":"Test"},"workspace":{"current_dir":"'$HOME'"},"context_window":{"used_percentage":42}}' | bash claude/statusline/statusline.sh`
   - 检查 `~/.claude/settings.json` 合并结果是否为合法 JSON，且本仓库条目已指向
     `claude/` 下的新路径、没有残留旧路径：
     `jq '[.statusLine.command, (.hooks[][].hooks[].command)] | map(select(test("cc_dev_env|coding_agents_env")))' ~/.claude/settings.json`
   - 通知链路 dry-run（不真发）：
     `echo '{"hook_event_name":"Stop","last_assistant_message":"测试","cwd":"'$PWD'"}' | NOTIFY_DRY_RUN=1 bash claude/hooks/notify.sh`
   - 若第 2 步配置了 IM 渠道（或迁移来的配置已有渠道），发一条测试通知让用户
     在手机上确认收到：
     `echo '{"hook_event_name":"Notification","notification_type":"permission_prompt","cwd":"'$PWD'"}' | bash claude/hooks/notify.sh`
     注意前台静音：终端窗口聚焦时不会真发，可临时 `NOTIFY_SKIP_WHEN_FOCUSED=0`
     加在命令前
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
- `lib/` — 三家共用的部分：
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
    翻译成 `send.sh` 的参数。xAI Grok CLI 会执行 Claude 的 hooks，其事件默认被
    忽略（`NOTIFY_FROM_GROK`）
  - `install.sh` 合并 `~/.claude/settings.json`
- `codex/` — Codex CLI（hooks.json 通知适配 + `[tui] status_line` 配置片段）
- `opencode/` — OpenCode（通知插件）

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
  运行时读取、带默认值），agent 专属的键加 `CLAUDE_` / `CODEX_` / `OPENCODE_`
  前缀；任何 `NOTIFY_*` 开关都支持加前缀只对某个 agent 生效。不要做进各 agent
  配置文件的 matcher——保证部署一次后调开关只改 notify.env、即时生效，
  不需要重装或重启
- 各 agent 目录的适配层只做"自家事件格式 → send.sh 参数"的翻译，开关、措辞、
  静音、推送不要复制到适配层里
- 新增 agent 时：建顶层目录，带自己的 `install.sh`（幂等，只动自己的条目），
  在根 `install.sh` 的检测列表里加一行，同步更新本文件和 README.md。新增
  定制模块时同理放进对应 agent 目录
