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

## Grok CLI 兼容入口

Grok CLI 会合并各来源的 hooks，默认仍扫描 `~/.claude/settings.json`；安装
原生 hooks 不会自动停止加载 Claude 兼容 hooks。本入口检测到非空
`GROK_HOOK_EVENT` 时始终直接退出，不检测原生 hooks 是否已安装，避免与
[`grok/hooks/notify.sh`](../../grok/README.md) 的原生入口重复通知；Claude Code
自己的事件不受影响。Grok 通知请执行 `bash install.sh grok` 安装原生 hooks，
不再经过这里，也不依赖 Claude Code。从旧实现升级时，git pull 到注册原生
hooks 之间 Grok 通知会暂停，需执行上述安装命令完成切换。

安装器不会修改 Grok 的 `[compat.claude] hooks` 或第三方 hooks；本仓库只跳过
自己的兼容事件，其他 Claude 兼容 hooks 继续按用户原有配置运行。Grok 通知
使用标准的 `GROK_NOTIFY_ON_*` 开关，详见 [Grok 配置](../../grok/README.md#配置)。

## 手工测试

```bash
cd claude/hooks
# dry-run：只打印判定和消息
echo '{"hook_event_name":"Notification","notification_type":"permission_prompt","cwd":"'$PWD'"}' | NOTIFY_DRY_RUN=1 bash notify.sh
echo '{"hook_event_name":"Stop","last_assistant_message":"测试消息","cwd":"'$PWD'"}' | NOTIFY_DRY_RUN=1 bash notify.sh
# 模拟 Grok 兼容调用：应无任何输出；Grok 通知只走原生入口
echo '{"hook_event_name":"Stop","lastAssistantMessage":"来自 Grok","cwd":"'$PWD'"}' | GROK_HOOK_EVENT=stop NOTIFY_DRY_RUN=1 bash notify.sh
# 真发到手机（终端聚焦时会被静音）
echo '{"hook_event_name":"Notification","notification_type":"permission_prompt","cwd":"'$PWD'"}' | NOTIFY_SKIP_WHEN_FOCUSED=0 bash notify.sh
```

在 Claude Code 里用 `/hooks` 确认 `Notification` 和 `Stop` 已注册。
