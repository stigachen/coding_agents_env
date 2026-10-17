# grok — Grok CLI

## 状态栏：`statusline/statusline.sh`

两行自定义状态栏，挂在 `${GROK_HOME:-$HOME/.grok}/config.toml` 的
`[ui.status_line]` 上，`type = "command"`，命令指向仓库里的脚本。
Grok 把一份 JSON 写到脚本的 stdin，脚本把 stdout 画到底部。缺字段就省略，
不显示占位符，也不把未知费用当成 `$0`。

```
Grok 4.7 (effort:high) | coding_agents_env | git:main@linked
ctx ████░░░░░░ 42% | $1.23
```

第一行是模型、`effort.level`、当前目录名、`workspace.branch`。链接 worktree
还有名字时写成 `git:分支@名字`；只有 worktree 名、没有分支时写成 `wt:名字`。
分支直接用 payload，不调用 `git`：回合进行中 Grok 会连续重跑这个脚本。

第二行是 context 进度条和本会话费用。`used_percentage` 为 0 会显示；字段缺失
则整段隐藏。颜色低于 60% 为绿，60% 到自动压缩阈值前为黄，达到
`auto_compact_threshold_percent`（没有则 80）起为红。费用低于 $0.005 或缺失
时不显示。

不显示订阅配额、脏文件数、回合计时、会话名和 Grok 版本。stdin 里没有配额，
也不去打未公开接口。不设置 `refresh_interval`；用户自己写的 `padding` 和
`refresh_interval` 重装时保留。脚本改动下次刷新即生效。`config.toml` 这一段
在启动时读取，安装或改表之后要重启 Grok。

细节和冒烟命令见 [statusline/README.md](statusline/README.md)。

## 通知：`hooks/notify.sh`

使用 Grok 原生的 `Stop` / `Notification` hooks，直接调用
[`lib/send.sh`](../lib/README.md)。无需安装 Claude Code。适配层只翻译事件；
开关、文案、前台静音和 Telegram / Discord /
macOS 桌面推送都由共用内核处理。

| Grok 事件 | `send.sh` kind | 说明 |
|---|---|---|
| 主会话 `Stop`，`reason=end_turn` | `stop` | 摘要取 `lastAssistantMessage` |
| `Notification` / `permission_prompt`（主会话或子 agent） | `permission` | Grok 的权限 UI 实际等待处理时触发；子 agent 的请求也保留 |
| 主会话 `Notification` / `idle_prompt` | `idle` | 会话停下后持续无人输入；也可能来自中断或出错的回合 |
| 会话退出 `Stop`（`shutdown` / `channel_closed`） | 不推送 | 退出进程不等于完成一个回合 |
| 子 agent 的 `Stop` / `idle_prompt`（`subagentType` 非空） | 不推送 | 避免把子任务结束或空闲当成主会话结束或空闲 |
| `Notification` / `task_complete` 及其他类型 | 不推送 | 不将这些事件推断为主会话回合完成 |

Grok 的字段使用 camelCase（`notificationType`、`lastAssistantMessage` 等）；
`hook_event_name` 提供 PascalCase 事件名，`hookEventName` / `GROK_HOOK_EVENT`
提供 snake_case 名。原生适配层按这些字段读取事件，不解析通知的显示文案。
子 agent 的 `permission_prompt` 仍通知：它也表示实际待审批，而且不保证父会话
另发一条相同请求。本 hook 不输出允许、拒绝或继续运行等决策，不改变 Grok 的
审批与停止流程。

## 部署逻辑（`install.sh`）

在仓库根目录执行：

```bash
bash install.sh grok    # 只安装 Grok
bash install.sh         # 自动检测已安装的 agent，包括 Grok
```

**从旧 Claude 兼容实现升级必须执行 `bash install.sh grok`。** 新版 Claude
入口会直接跳过 Grok 事件，所以只 git pull、尚未注册原生 hooks 的这段时间，
Grok 通知会暂停；完成原生安装后按标准 `GROK_NOTIFY_ON_*` / `NOTIFY_ON_*` 发送。

入口脚本生成 / 迁移 / 补齐共用的 `notify.env`，随后 `grok/install.sh` 做两件事：

- 在 `${GROK_HOME:-$HOME/.grok}/hooks/coding_agents_env.json` 注册 `Stop` 和
  `Notification`，命令引用仓库里 `grok/hooks/notify.sh` 的绝对路径
- 在同一目录的 `config.toml` 写入 `[ui.status_line]` 的 `type` 和 `command`，
  指向 `grok/statusline/statusline.sh`。按 TOML 结构合并，能识别带空格或引号的
  表头、引号键、inline table、点号键和多行字符串；字符串里的假表头不会被改写。
  根级 `ui = { ... }` 在这张 inline table 里写入 `status_line`，不在文件末尾追加子表。
  其他表和键保留。原来的 command 不是本仓库脚本时，会在 stderr 提示已接管。
  认不出或无法安全改写时安装失败，原文件保持不动。`config.toml` 是软链时改目标文件，
  成功改写前把目标复制为旁边的 `config.toml.bak`（每次安装覆盖上一份备份）

代码不拷贝。仓库移动后重跑安装；通常的脚本更新随 git pull 生效。状态栏表在
下次启动 Grok 时加载。

Grok 会合并原生、Claude 兼容等来源的 hooks；**注册原生 hooks 后，默认仍
扫描 Claude 配置**。安装器只管理本仓库条目，不动其他 hook 文件、第三方条目
或 Grok 全局 `[compat.claude]` 配置。本仓库的 Claude 适配层看到非空
`GROK_HOOK_EVENT` 就直接退出，无论是否已注册原生 hooks，也不做安装状态检测。
这样只跳过本仓库自己的兼容事件；其他 Claude 兼容 hooks 继续按用户原配置工作。

脚本兼容 macOS 自带 Bash 3.2 与 Windows Git Bash；依赖 `bash`、`jq`、
`curl`、`git`，与仓库其他模块一致。

Windows 上 hook 和状态栏命令写成 Git Bash 的 `bash.exe` 绝对路径（`C:/...`），
不用 PATH 里的 `bash`（那经常是 WSL 启动器）。查找顺序是
`CLAUDE_CODE_GIT_BASH_PATH`、`Program Files\Git`、`%LOCALAPPDATA%\Programs\Git`、
`Program Files (x86)\Git`，最后才看 PATH 里不是 System32 的 bash。找不到就安装
失败。Hook 命令不加 PowerShell 的 `&`：Grok 会给「引号里的程序路径，后面还有
参数」自行补上调用运算符。状态栏没有这步改写，命令行按原样交给检测到的
shell，所以写成 `& 'bash.exe' 'statusline.sh'`。已安装的机器需要重跑
`bash install.sh grok`，旧命令才会换成新路径；状态栏表仍在下次启动 Grok 时加载。

## 配置

密钥和开关仍只放在 `~/.config/coding_agents_env/notify.env`（chmod 600），
不写入 Grok hook JSON 或仓库。可用 `CODING_AGENTS_ENV_DIR` 指定共用配置目录。

- `GROK_NOTIFY_ON_STOP`、`GROK_NOTIFY_ON_PERMISSION`、`GROK_NOTIFY_ON_IDLE`：
  分别控制回合结束、待审批、等输入；未设置时继承公共 `NOTIFY_ON_*`。
- 渠道、桌面通知、前台静音等同样支持 `GROK_` 覆盖，例如
  `GROK_DISCORD_WEBHOOK_URL`、`GROK_DESKTOP_NOTIFY`、`GROK_NOTIFY_SKIP_WHEN_FOCUSED`。
  Telegram token / chat_id 需成对覆盖，规则见 [共用内核](../lib/README.md)。

原生通知没有额外总开关，只使用上述标准开关。遗留的 `NOTIFY_FROM_GROK` /
`GROK_NOTIFY_FROM_GROK` 不再参与通知判断，即使值为 0 也不抑制原生通知；
安装器不生成、迁移或删除这些旧键，用户文件里的旧键可自行清理。改标准开关
下次事件即生效，无需重装。

`GROK_NOTIFY_DEBUG=1`（或公共 `NOTIFY_DEBUG=1`）时，Grok 的日志写入
`${CODING_AGENTS_ENV_DIR:-$HOME/.config/coding_agents_env}/notify-debug.log`，
无需 `~/.claude` 目录。其他 agent 的日志仍保留在原位置。

## Stop gate 的限制

Grok 的 `Stop` 是停止前的 gate。若其他 Stop hook 阻止停止、要求继续执行，
同一回合会再次触发 `Stop`；被动通知 hook 无法知道哪一次最终允许回合结束。
`stopHookActive=true` 既可能出现在中间轮，也可能出现在最终轮，不能用它可靠
去重。因此与阻止停止的 hook 共用时，可能提前或重复发送完成通知；过滤
`reason=end_turn` 只能排除退出会话的额外事件，不能解决这个限制。

这种组合下可设 `GROK_NOTIFY_ON_STOP=0`，保留 `GROK_NOTIFY_ON_IDLE=1`，用
持续空闲的提醒确认需要回来看任务。`idle_prompt` 表示已停下，不保证执行成功。

## 隔离 dry-run

以下命令在仓库根目录执行，只用临时配置和默认标准开关；不修改本机配置、
不读取本机 IM 凭据，也不会真发通知。前四条分别输出主会话 stop /
permission / idle、子 agent permission，最后四条应无输出：

```bash
grok_test_dir=$(mktemp -d)
printf 'NOTIFY_DEBUG=0\n' > "$grok_test_dir/notify.env"
env -i PATH="$PATH" CODING_AGENTS_ENV_DIR="$grok_test_dir" \
  CLAUDE_CONFIG_DIR="$grok_test_dir" \
  NOTIFY_DRY_RUN=1 NOTIFY_SKIP_WHEN_FOCUSED=0 bash <<'GROK_TEST'
  printf '%s' '{"hook_event_name":"Stop","cwd":"/tmp/demo","reason":"end_turn","lastAssistantMessage":"测试摘要"}' | bash grok/hooks/notify.sh
  printf '%s' '{"hook_event_name":"Notification","cwd":"/tmp/demo","notificationType":"permission_prompt"}' | bash grok/hooks/notify.sh
  printf '%s' '{"hook_event_name":"Notification","cwd":"/tmp/demo","notificationType":"idle_prompt"}' | bash grok/hooks/notify.sh
  printf '%s' '{"hook_event_name":"Notification","cwd":"/tmp/demo","notificationType":"permission_prompt","subagentType":"explore"}' | bash grok/hooks/notify.sh
  printf '%s' '{"hook_event_name":"Stop","cwd":"/tmp/demo","reason":"shutdown"}' | bash grok/hooks/notify.sh
  printf '%s' '{"hook_event_name":"Stop","cwd":"/tmp/demo","reason":"end_turn","subagentType":"explore"}' | bash grok/hooks/notify.sh
  printf '%s' '{"hook_event_name":"Notification","cwd":"/tmp/demo","notificationType":"idle_prompt","subagentType":"explore"}' | bash grok/hooks/notify.sh
  printf '%s' '{"hook_event_name":"Notification","cwd":"/tmp/demo","notificationType":"task_complete"}' | bash grok/hooks/notify.sh
GROK_TEST
rm -f "$grok_test_dir/notify.env"
rmdir "$grok_test_dir"
```

安装后可用 `jq . "${GROK_HOME:-$HOME/.grok}/hooks/coding_agents_env.json"` 检查
注册结果，重启 Grok 会话加载配置。dry-run 只验证适配和消息生成，不等于实际
渠道送达或 Grok 完整生命周期的验证。
