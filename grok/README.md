# grok — Grok CLI

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

入口脚本生成 / 迁移 / 补齐共用的 `notify.env`，随后 `grok/install.sh` 在
`${GROK_HOME:-$HOME/.grok}/hooks/coding_agents_env.json` 注册 `Stop` 和
`Notification`。命令引用仓库里 `grok/hooks/notify.sh` 的绝对路径，代码不拷贝；
仓库移动后重跑安装，通常的脚本更新随 git pull 生效。

Grok 会合并原生、Claude 兼容等来源的 hooks；**注册原生 hooks 后，默认仍
扫描 Claude 配置**。安装器只管理本仓库条目，不动其他 hook 文件、第三方条目
或 Grok 全局 `[compat.claude]` 配置。本仓库的 Claude 适配层看到非空
`GROK_HOOK_EVENT` 就直接退出，无论是否已注册原生 hooks，也不做安装状态检测。
这样只跳过本仓库自己的兼容事件；其他 Claude 兼容 hooks 继续按用户原配置工作。

脚本兼容 macOS 自带 Bash 3.2 与 Windows Git Bash；依赖 `bash`、`jq`、
`curl`、`git`，与仓库其他模块一致。

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
