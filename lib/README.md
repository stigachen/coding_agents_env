# lib — 各 agent 共用的通知内核

把 coding agent 的关键事件推送到手机/IM，解决"命令行窗口放到后台就看不见了"
的问题。Claude Code / Codex / OpenCode 各自的目录里只有一层薄适配，把自家事件
翻译成这里的调用；开关、措辞、前台静音、渠道推送全在这里，三家行为一致。

| kind | 含义 | 通知内容 |
|---|---|---|
| `permission` | agent 在等你批准一个操作 | 🔔 [项目@主机] Claude 在等你批准一个操作 |
| `idle` | agent 停下后一段时间无人输入 | ⏸️ [项目@主机] Claude 已停下，等待你的输入 |
| `stop` | 回合结束 | ✅ [项目@主机] Claude 任务完成 + 最后回复摘要 |
| `stop_without_transcript` | 明确未提供会话记录路径的回合结束 | 默认静音；开启后与 `stop` 相同 |
| `other` | 其他通知 | 🔔 [项目@主机] Claude 通知：<正文> |

消息里的 agent 名随调用方变化（Claude / Codex / OpenCode / Grok）。前缀里的
主机名用于多台机器共用一个 IM 渠道时分辨来源（`NOTIFY_SHOW_HOST=0` 可去掉）。

## 组成

- `send.sh` — 内核。用法：
  ```bash
  printf '%s' "<正文>" | bash lib/send.sh <kind> <project> <agent>
  ```
  `project` 一般是 cwd 的 basename；`agent` 显示在消息里，同时决定按 agent
  覆盖的开关前缀。任何渠道未配置即跳过；全部未配置则静默退出，不影响 agent
  正常运行。`NOTIFY_DRY_RUN=1` 时只把判定结果和最终消息打到 stdout、不推送。
- `focus_check.ps1` — Windows 前台检测（见下文"前台静音"），由 `send.sh`
  在 Git Bash 下调用，输出 FOCUSED / AWAY / NO。
- `notify.env.example` — 配置模板。真实配置放 `~/.config/coding_agents_env/notify.env`
  （机器本地，含 token，**不入库**，chmod 600 仅本人可读），`install.sh`
  首次运行会自动生成空模板，旧版仓库的 `~/.claude/notify.env` 会被自动迁移。
  `send.sh` 找不到新位置时也会回退读旧位置。

## 支持的渠道

- **Telegram**：`TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID`。
  找 [@BotFather](https://t.me/BotFather) 建 bot 拿 token；给 bot 发条消息后访问
  `https://api.telegram.org/bot<TOKEN>/getUpdates` 查 chat_id。
- **Discord**：`DISCORD_WEBHOOK_URL`。服务器设置 → 整合 → Webhook → 复制 URL，
  无需注册 bot。
- 以上渠道键都可以加 agent 前缀（`OPENCODE_DISCORD_WEBHOOK_URL=…`）让某个
  agent 推到别的群/频道，留空（`CODEX_DISCORD_WEBHOOK_URL=`）则该 agent 不发这个
  渠道。Telegram 的两个键要成对覆盖。详见下文"按 agent 覆盖"。
- **macOS 桌面通知**：`DESKTOP_NOTIFY=1`。人在电脑前但窗口在后台时的轻量提醒
  （`osascript`，无外网依赖）。

## 开关与降噪

**所有开关集中在 `~/.config/coding_agents_env/notify.env`，改完即时生效**
（下次事件触发时读取），无需重跑 `install.sh`、也无需重启会话。各 agent 的
hook 配置里不设 matcher 过滤，事件先到 `send.sh` 再按开关决定推不推：

| 开关 | 默认 | 作用 |
|---|---|---|
| `NOTIFY_ON_PERMISSION` | 1 | 待审批通知 |
| `NOTIFY_ON_IDLE` | 1 | 等输入通知 |
| `NOTIFY_ON_STOP` | 1 | 回合结束通知 |
| `CODEX_NOTIFY_ON_STOP_WITHOUT_TRANSCRIPT` | 0 | Codex 明确未提供会话记录路径的完成通知；设 1 恢复，仍受 `NOTIFY_ON_STOP` / `CODEX_NOTIFY_ON_STOP` 控制，范围见 [Codex 说明](../codex/README.md#未提供会话记录路径的完成通知) |
| `NOTIFY_SKIP_WHEN_FOCUSED` | 1 | 前台静音（见下文） |
| `NOTIFY_FOCUS_MAX_IDLE` | 120 | 前台静音的"人已走开"阈值（秒） |
| `DESKTOP_NOTIFY` | 0 | macOS 本机桌面弹窗 |
| `NOTIFY_SHOW_HOST` | 1 | 消息前缀带主机名 `[项目@主机]` |
| `NOTIFY_DEBUG` | 0 | 排障日志，写入 `~/.claude/notify-debug.log` |
| `NOTIFY_FROM_GROK` | 0 | （Claude 专属）是否推送 Grok CLI 触发的事件，见 [claude/hooks/README.md](../claude/hooks/README.md) |
| `CLAUDE_STATUSLINE_USAGE_API` | 0 | （Claude 状态栏用）设 1 后额外显示按模型的周配额，详见 [claude/statusline/README.md](../claude/statusline/README.md) |

**临时覆盖**：环境变量或命令行前缀里已设的键优先于文件，测试时可以
`NOTIFY_SKIP_WHEN_FOCUSED=0 NOTIFY_DEBUG=1 bash lib/send.sh …` 临时改行为，
不用动文件。

**按 agent 覆盖**：任何 `NOTIFY_*` 开关、`DESKTOP_NOTIFY` 以及渠道键
（`TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` / `DISCORD_WEBHOOK_URL`）都可以加
前缀只对某个 agent 生效，前缀是 agent 名大写：`CODEX_NOTIFY_ON_STOP=0` 只关掉
Codex 的回合结束通知，`OPENCODE_DESKTOP_NOTIFY=1` 只给 OpenCode 开桌面弹窗，
`OPENCODE_DISCORD_WEBHOOK_URL=…` 让 OpenCode 推到另一个 Discord 频道。查找顺序：
`<AGENT>_KEY` → `KEY` → 默认值，判的是"是否设置"而非"是否非空"：前缀键留空
（`CODEX_DISCORD_WEBHOOK_URL=`）表示对该 agent 明确关掉，不回退通用键。
`TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` 成对解析，只覆盖其中一个会跳过
Telegram（`NOTIFY_DEBUG=1` 时日志里有提示）。

`stop` 每个回合都触发，包括你在旁边正常交互的短回合。嫌吵可设
`NOTIFY_ON_STOP=0`，只保留"待审批 / 等输入"两类通知 ——
"等输入"本身就意味着 agent 停了一阵没人理，天然等价于"你不在电脑前"。

### 前台静音（默认开启）

agent 所在终端窗口**有键盘焦点**时，跳过所有推送（IM + 桌面弹窗）——
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
  时去 `\r`、`send.sh` 加载时再去一次 —— 即使用 Windows 编辑器把
  `notify.env` 存成 CRLF 也不会污染 token。
- `chmod 600` 在 NTFS 上只是尽力而为（实际权限由 Windows ACL 管理，文件在你的
  用户目录下默认其他用户不可读）。旧版 `~/.claude/notify.env` 迁移时 Windows
  上不建软链（Git Bash 的 `ln -s` 默认是复制），旧文件改名为 `notify.env.migrated`。
- `focus_check.ps1` 带 UTF-8 BOM 且需保留：Windows PowerShell 5.1 读无 BOM
  脚本时按 ANSI 代码页解码，中文注释会乱码。
- 整个 hook 必须在 agent 配置的超时内跑完，超时会被整体强杀、通知静默
  丢失——所以 `focus_check.ps1` 的进程祖先链上溯用一次全表查询在内存里完成
  （逐跳 `Get-CimInstance` 每次约 0.6s，长链会耗尽预算），`send.sh` 调用它
  时再套一层 `timeout 6` 兜底（超时按未聚焦处理，宁可多推不可丢）。
- 推送优先用系统原生 `System32\curl.exe`（不存在时退回 `curl`），消息数据
  全走 stdin，两种 curl 下 UTF-8 均不受 argv 编码转换影响。
- 排障时设 `NOTIFY_DEBUG=1`，每次事件的判定和推送结果（curl 退出码与响应）
  会写入 `~/.claude/notify-debug.log`。

## 手工测试

```bash
# 只看判定和消息，不真发
printf '' | NOTIFY_DRY_RUN=1 bash lib/send.sh permission myproj Claude
printf '测试摘要' | NOTIFY_DRY_RUN=1 bash lib/send.sh stop myproj Codex
# 真发（终端聚焦时会被静音，加 NOTIFY_SKIP_WHEN_FOCUSED=0 强制发）
printf '' | NOTIFY_SKIP_WHEN_FOCUSED=0 bash lib/send.sh permission myproj Claude
```

各 agent 适配层的测试见其目录下的 README。
