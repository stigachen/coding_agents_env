# claude/hooks — Claude Code 通知适配层

`notify.sh` 是 Claude Code 的 `Notification` 和 `Stop` 两个 hook 事件的入口。
它只把 Claude Code 从 stdin 传来的事件 JSON（`hook_event_name`、
`notification_type`、`cwd`、`last_assistant_message` 等）翻译成
[`lib/send.sh`](../../lib/README.md) 的调用；开关、措辞、前台静音、渠道推送
全在 `send.sh`，各开关说明和排障也见那里。

| Claude 事件 | `send.sh` kind |
|---|---|
| `Notification` / `permission_prompt`（权限提示弹出约 6 秒无人处理） | `permission` |
| `Notification` / `idle_prompt`（回合结束后约 60 秒无输入） | `idle` |
| `Stop`（每个回合结束，附最后回复摘要） | `stop` |
| `Notification` / 其他类型 | `other` |

`claude/install.sh` 把两个 hook 注册进 `~/.claude/settings.json`，不设 matcher
（放行所有通知类型），事件到 `send.sh` 后再按 `notify.env` 的开关过滤。
只增删本仓库自己的条目（按 `/hooks/notify.sh` 路径特征识别），其他工具注册的
hook 一律不动。

## 来自 Grok CLI 的事件（默认忽略）

xAI 的 Grok CLI 带 "Claude Code 兼容" 功能（`~/.grok/config.toml` 里
`[compat.claude] hooks`，默认开），会原样执行 `~/.claude/settings.json` 中的
hooks——于是 Grok 的每个回合结束、每条 idle 提示也会跑到 `notify.sh`，推出
一堆没有正文、类型显示为 `notification` 的"任务完成"（Grok 的载荷是
camelCase：`lastAssistantMessage` / `notificationType`，且 Grok 会话结束时也
触发一次 `Stop`）。

`notify.sh` 通过 Grok 为每个 hook 注入的 `GROK_HOOK_EVENT` 环境变量识别调用方，
把 agent 标成 `Grok` 交给 `send.sh`：

- `NOTIFY_FROM_GROK=0`（默认）：Grok 触发的事件一律忽略，Claude Code 的不受影响。
- `NOTIFY_FROM_GROK=1`：照常推送，消息里标成 "Grok"，字段按 camelCase 读取，
  `NOTIFY_ON_*` 各开关同样生效（也可用 `GROK_` 前缀单独设）。

不想让 Grok 碰 Claude 的 hooks，也可以在 Grok 侧关掉：`~/.grok/config.toml`
加 `[compat.claude]` / `hooks = false`，或设环境变量 `GROK_CLAUDE_HOOKS_ENABLED=0`。

## 手工测试

```bash
cd claude/hooks
# dry-run：只打印判定和消息
echo '{"hook_event_name":"Notification","notification_type":"permission_prompt","cwd":"'$PWD'"}' | NOTIFY_DRY_RUN=1 bash notify.sh
echo '{"hook_event_name":"Stop","last_assistant_message":"测试消息","cwd":"'$PWD'"}' | NOTIFY_DRY_RUN=1 bash notify.sh
# 模拟 Grok 调用：默认应无任何输出；notify.env 设 NOTIFY_FROM_GROK=1 后会标为 Grok
echo '{"hook_event_name":"Stop","lastAssistantMessage":"来自 Grok","cwd":"'$PWD'"}' | GROK_HOOK_EVENT=stop NOTIFY_DRY_RUN=1 bash notify.sh
# 真发到手机（终端聚焦时会被静音）
echo '{"hook_event_name":"Notification","notification_type":"permission_prompt","cwd":"'$PWD'"}' | NOTIFY_SKIP_WHEN_FOCUSED=0 bash notify.sh
```

在 Claude Code 里用 `/hooks` 确认 `Notification` 和 `Stop` 已注册。
