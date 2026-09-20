# cc_dev_env — Claude Code 环境定制仓库

这个仓库集中管理我个人的 Claude Code 环境定制（statusline、hooks 通知等），
目标是在任何新开发机上 clone 下来即可一键部署。

## 自动部署（重要）

当用户要求"把这个目录的配置安装到这台电脑"、"部署这些定制"、"install/setup
这个仓库"或任何同义表述时，执行以下流程：

1. 运行 `bash install.sh`（幂等，可放心重复执行；脚本本身非交互——它由 Claude
   的 Bash 工具执行，stdin 不是 TTY，任何交互都放在下面第 2 步由对话完成）。它会：
   - 在 `~/.claude/settings.json` 写入 statusLine 配置和 Notification/Stop hooks，
     命令指向本仓库内脚本的绝对路径（git pull 即生效，不拷贝文件）
   - 若 `~/.claude/notify.env` 不存在，从 `hooks/notify.env.example` 生成模板
     并 chmod 600；已存在则自动补齐模板新增的开关（追加缺失的 KEY=默认值，
     不动已填的值）
2. **交互式收集通知渠道配置**。检查 `~/.claude/notify.env`：若关键项均为空
   （TELEGRAM_BOT_TOKEN / DISCORD_WEBHOOK_URL 都没填），在对话中询问用户：
   - 用哪个通知渠道？（Telegram / Discord / 两者 / 暂不配置）
   - 对应的凭据：Telegram 要 bot token + chat_id（用户没有的话，指引：找
     @BotFather 建 bot；给 bot 发条消息后访问
     `https://api.telegram.org/bot<TOKEN>/getUpdates` 查 chat_id）；
     Discord 要 webhook URL（服务器设置 → 整合 → Webhook）
   - 是否开启回合结束通知（NOTIFY_ON_STOP，默认 1）和 macOS 桌面弹窗（DESKTOP_NOTIFY）。
     其余开关（NOTIFY_ON_PERMISSION / NOTIFY_ON_IDLE / 前台静音等，全表见
     hooks/README.md）默认值即合理，不要逐一询问；告知用户以后随时改
     `~/.claude/notify.env` 即可，即时生效
   把用户的回答写入 `~/.claude/notify.env`（保持 KEY=VALUE 格式，chmod 600）。
   用户选"暂不配置"则跳过，不要反复追问。
   凭据处理纪律：token 只写入该文件，不回显完整值、不写进仓库任何文件、
   不出现在 git 提交中。
3. 验证：
   - statusline 冒烟测试：
     `echo '{"model":{"display_name":"Test"},"workspace":{"current_dir":"'$HOME'"},"context_window":{"used_percentage":42}}' | bash statusline/statusline.sh`
   - 检查 `~/.claude/settings.json` 合并结果是否为合法 JSON：`jq . ~/.claude/settings.json`
   - 若第 2 步配置了 IM 渠道，发一条测试通知让用户在手机上确认收到：
     `echo '{"hook_event_name":"Notification","notification_type":"permission_prompt","cwd":"'$PWD'"}' | bash hooks/notify.sh`
4. 提醒用户：
   - 状态栏用量默认只显示 Claude Code 喂给 stdin 的 session/weekly；想看按模型的
     周配额需把 `~/.claude/notify.env` 的 `STATUSLINE_USAGE_API` 设 1（用本机 OAuth
     token 调未公开接口，默认关闭，不要替用户打开）。开启后 macOS 若弹 Keychain
     授权选 "Always Allow"，不授权时脚本自动回退读 `~/.claude/.credentials.json`
   - 重启 Claude Code 会话，用 `/hooks` 确认 hooks 已注册

依赖：`bash` `curl` `git` `jq`。缺 `jq` 时 macOS 用 `brew install jq`，
Windows Git Bash 把 `jq.exe` 放进 PATH。

## 仓库结构

- `install.sh` — 一键部署入口（合并 settings.json，幂等）
- `statusline/` — 两行状态栏：模型/effort/git 分支 + context 进度条 + 订阅配额
  （session/weekly 取自 Claude Code 喂给 stdin 的 `rate_limits`；按模型周配额走
  未公开接口，由 `notify.env` 的 `STATUSLINE_USAGE_API` 控制，默认关）
- `hooks/` — `notify.sh`：Notification（待审批/等输入）和 Stop（回合结束）事件
  推送到 Telegram/Discord/macOS 桌面通知；终端窗口有键盘焦点时自动静音
  （`focus_check.ps1` 为 Windows 检测端）；渠道密钥和**所有通知开关**都在
  `~/.claude/notify.env`（不入库）——部署后启停各类通知只改这一个文件，
  即时生效（install.sh 重跑时会自动补齐模板新增的开关）。消息前缀带主机名
  （多机共用渠道时区分来源）；xAI Grok CLI 会执行 Claude 的 hooks，其事件
  默认被忽略（`NOTIFY_FROM_GROK`）

## 约定

- 所有 `*.sh` 必须 LF 结尾、兼容 bash 3.2（macOS 自带）与 Git Bash（Windows），
  多字节字符输出用 printf 八进制转义（原因见 statusline/README.md）
- 密钥（IM token 等）一律放 `~/.claude/notify.env` 这类机器本地文件，绝不进仓库
- 通知行为和状态栏的开关一律加在 `notify.env`（由 `notify.sh` / `statusline.sh`
  运行时读取、带默认值），
  不要做进 settings.json 的 matcher——保证部署一次后调开关只改 notify.env、
  即时生效，不需要重装或重启
- 新增定制模块时：脚本放独立子目录，部署逻辑加进 `install.sh` 并保持幂等，
  同步更新本文件和 README.md
