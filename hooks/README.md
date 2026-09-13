# hooks — IM 通知

把 Claude Code 的关键事件推送到手机/IM，解决"命令行窗口放到后台就看不见了"的问题。

| 事件 | 触发时机 | 通知内容 |
|---|---|---|
| `Notification` / `permission_prompt` | 权限提示弹出约 6 秒无人处理 | 🔔 [项目@主机] Claude 在等你批准一个操作 |
| `Notification` / `idle_prompt` | 回合结束后约 60 秒无输入 | ⏸️ [项目@主机] Claude 已停下，等待你的输入 |
| `Stop` | 每个回合结束 | ✅ [项目@主机] Claude 任务完成 + 最后回复摘要 |

前缀里的主机名用于多台机器共用一个 IM 渠道时分辨来源（`NOTIFY_SHOW_HOST=0` 可去掉）。

## 组成

- `notify.sh` — hook 入口。Claude Code 把事件 JSON 从 stdin 传入
  （`hook_event_name`、`notification_type`、`cwd`、`last_assistant_message` 等），
  脚本组装消息后发往所有已配置的渠道。任何渠道未配置即跳过；全部未配置则静默退出，
  不影响 Claude Code 正常运行。
- `focus_check.ps1` — Windows 前台检测（见下文"前台静音"），由 `notify.sh`
  在 Git Bash 下调用，输出 FOCUSED / AWAY / NO。
- `notify.env.example` — 渠道配置模板。真实配置放 `~/.claude/notify.env`
  （机器本地，含 token，**不入库**，chmod 600 仅本人可读），`install.sh`
  首次运行会自动生成空模板。用"让 Claude Code 自己装"的方式部署时，Claude
  会在对话里询问渠道和凭据并替你写入；手动部署则自己编辑该文件。

## 支持的渠道

- **Telegram**：`TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID`。
  找 [@BotFather](https://t.me/BotFather) 建 bot 拿 token；给 bot 发条消息后访问
  `https://api.telegram.org/bot<TOKEN>/getUpdates` 查 chat_id。
- **Discord**：`DISCORD_WEBHOOK_URL`。服务器设置 → 整合 → Webhook → 复制 URL，
  无需注册 bot。
- **macOS 桌面通知**：`DESKTOP_NOTIFY=1`。人在电脑前但窗口在后台时的轻量提醒
  （`osascript`，无外网依赖）。

## 开关与降噪

**所有开关集中在 `~/.claude/notify.env`，改完即时生效**（下次事件触发时读取），
无需重跑 `install.sh`、也无需重启会话。settings.json 里的 hook 不设 matcher
过滤，事件先到 `notify.sh` 再按开关决定推不推：

| 开关 | 默认 | 作用 |
|---|---|---|
| `NOTIFY_ON_PERMISSION` | 1 | 待审批通知（`permission_prompt`） |
| `NOTIFY_ON_IDLE` | 1 | 等输入通知（`idle_prompt`） |
| `NOTIFY_ON_STOP` | 1 | 回合结束通知（`Stop`） |
| `NOTIFY_SKIP_WHEN_FOCUSED` | 1 | 前台静音（见下文） |
| `NOTIFY_FOCUS_MAX_IDLE` | 120 | 前台静音的"人已走开"阈值（秒） |
| `DESKTOP_NOTIFY` | 0 | macOS 本机桌面弹窗 |
| `NOTIFY_SHOW_HOST` | 1 | 消息前缀带主机名 `[项目@主机]` |
| `NOTIFY_FROM_GROK` | 0 | 是否推送 Grok CLI 触发的事件（见下文） |
| `NOTIFY_DEBUG` | 0 | 排障日志，写入 `~/.claude/notify-debug.log` |

`Stop` 每个回合都触发，包括你在旁边正常交互的短回合。嫌吵可设
`NOTIFY_ON_STOP=0`，只保留"待审批 / 等输入"两类通知 ——
`idle_prompt` 本身就意味着"Claude 停了 60 秒没人理"，天然等价于"你不在电脑前"。

### 来自 Grok CLI 的事件（默认忽略）

xAI 的 Grok CLI 带 "Claude Code 兼容" 功能（`~/.grok/config.toml` 里
`[compat.claude] hooks`，默认开），会原样执行 `~/.claude/settings.json` 中的
hooks——于是 Grok 的每个回合结束、每条 idle 提示也会跑到 `notify.sh`，推出
一堆没有正文、类型显示为 `notification` 的"Claude 任务完成"（Grok 的载荷是
camelCase：`lastAssistantMessage` / `notificationType`，且 Grok 会话结束时也
触发一次 `Stop`）。

`notify.sh` 通过 Grok 为每个 hook 注入的 `GROK_HOOK_EVENT` 环境变量识别调用方：

- `NOTIFY_FROM_GROK=0`（默认）：Grok 触发的事件一律忽略，Claude Code 的不受影响。
- `NOTIFY_FROM_GROK=1`：照常推送，消息里标成 "Grok"，字段按 camelCase 读取，
  `NOTIFY_ON_*` 各开关同样生效。

不想让 Grok 碰 Claude 的 hooks，也可以在 Grok 侧关掉：`~/.grok/config.toml`
加 `[compat.claude]` / `hooks = false`，或设环境变量 `GROK_CLAUDE_HOOKS_ENABLED=0`。

### 前台静音（默认开启）

Claude Code 所在终端窗口**有键盘焦点**时，跳过所有推送（IM + 桌面弹窗）——
你正盯着屏幕，没必要再震手机。`NOTIFY_SKIP_WHEN_FOCUSED=0` 可关闭。

实现要点：

- **判焦点，不判可见**。系统里焦点窗口永远只有一个，多显示器下窗口在副屏
  可见但焦点在别的应用时仍会推送（可见 ≠ 在看）。
- **不硬编码终端名单**。把前台窗口的属主进程和 hook 自身的祖先进程链比对：
  终端 / IDE（Terminal、iTerm2、Windows Terminal、VS Code 内置终端…）必然是
  hook 进程的祖先，命中即视为聚焦。换终端 app 无需改配置。
- **人已走开兜底**。窗口聚焦但全局无键鼠输入超过 `NOTIFY_FOCUS_MAX_IDLE` 秒
  （默认 120）则照常推送——防止"窗口留在前台就永远收不到通知"。
- **锁屏显式检测**。手动立即锁屏（macOS Ctrl+Cmd+Q / Windows Win+L）时按键
  会清零空闲计时，单靠空闲阈值会有一段误静音窗口，因此额外显式判断锁屏状态
  （macOS 查 IORegistry 的 `CGSSessionScreenIsLocked`，Windows 查 LogonUI
  进程），已锁屏一律照常推送。自动锁屏（空闲触发）本身就被空闲阈值覆盖。
- **检测失败一律照发（fail-open）**。SSH 远程、tmux/screen（祖先链在 server
  进程处断裂）、无 GUI、缺工具等场景都不会误吞通知。
- 平台实现：macOS 用 `lsappinfo`（不触发 TCC 自动化授权弹窗）+ `ioreg` 读
  空闲时间；Windows Git Bash 用 `focus_check.ps1`（`GetForegroundWindow` +
  父进程链，经典 conhost 额外用 `GetConsoleWindow` 句柄直接比对，空闲用
  `GetLastInputInfo`）。

已知限制：只能判断到**窗口/应用级**。同一终端 app 开了多个窗口或 tab 时，
只要该 app（macOS）/该窗口（Windows Terminal）聚焦，所有会话的通知都会被
静音，即使聚焦的是别的 tab——此时终端就在眼前，代价可接受。tmux 内运行时
检测恒为"未聚焦"（照常推送）。

## Windows (Git Bash) 说明

- Telegram / Discord 通知完全可用；桌面弹窗目前仅 macOS（`DESKTOP_NOTIFY` 在
  Windows 上自动跳过）。
- 行尾三层防护：`.gitattributes` 钉住模板为 LF、`install.sh` 生成 `notify.env`
  时去 `\r`、`notify.sh` 加载时再去一次 —— 即使用 Windows 编辑器把
  `notify.env` 存成 CRLF 也不会污染 token。
- `chmod 600` 在 NTFS 上只是尽力而为（实际权限由 Windows ACL 管理，文件在你的
  用户目录下默认其他用户不可读）。
- `focus_check.ps1` 带 UTF-8 BOM 且需保留：Windows PowerShell 5.1 读无 BOM
  脚本时按 ANSI 代码页解码，中文注释会乱码。
- 整个 hook 必须在 settings 的 `timeout` 内跑完，超时会被整体强杀、通知静默
  丢失——所以 `focus_check.ps1` 的进程祖先链上溯用一次全表查询在内存里完成
  （逐跳 `Get-CimInstance` 每次约 0.6s，长链会耗尽预算），`notify.sh` 调用它
  时再套一层 `timeout 6` 兜底（超时按未聚焦处理，宁可多推不可丢）。
- 推送优先用系统原生 `System32\curl.exe`（不存在时退回 `curl`），消息数据
  全走 stdin，两种 curl 下 UTF-8 均不受 argv 编码转换影响。
- 排障时设 `NOTIFY_DEBUG=1`，每次事件的判定和推送结果（curl 退出码与响应）
  会写入 `~/.claude/notify-debug.log`。

## 手工测试

```bash
echo '{"hook_event_name":"Notification","notification_type":"permission_prompt","cwd":"'$PWD'"}' | bash notify.sh
echo '{"hook_event_name":"Stop","last_assistant_message":"测试消息","cwd":"'$PWD'"}' | bash notify.sh
# 模拟 Grok 调用：默认应无任何推送；notify.env 设 NOTIFY_FROM_GROK=1 后会收到标为 Grok 的消息
echo '{"hook_event_name":"Stop","lastAssistantMessage":"来自 Grok","cwd":"'$PWD'"}' | GROK_HOOK_EVENT=stop bash notify.sh
```

配置了渠道的话，手机应立刻收到前两条通知（第三条默认静默）。在 Claude Code 里用 `/hooks`
确认 `Notification` 和 `Stop` 已注册。
