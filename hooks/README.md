# hooks — IM 通知

把 Claude Code 的关键事件推送到手机/IM，解决"命令行窗口放到后台就看不见了"的问题。

| 事件 | 触发时机 | 通知内容 |
|---|---|---|
| `Notification` / `permission_prompt` | 权限提示弹出约 6 秒无人处理 | 🔔 [项目] Claude 在等你批准一个操作 |
| `Notification` / `idle_prompt` | 回合结束后约 60 秒无输入 | ⏸️ [项目] Claude 已停下，等待你的输入 |
| `Stop` | 每个回合结束 | ✅ [项目] Claude 任务完成 + 最后回复摘要 |

## 组成

- `notify.sh` — hook 入口。Claude Code 把事件 JSON 从 stdin 传入
  （`hook_event_name`、`notification_type`、`cwd`、`last_assistant_message` 等），
  脚本组装消息后发往所有已配置的渠道。任何渠道未配置即跳过；全部未配置则静默退出，
  不影响 Claude Code 正常运行。
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

## 降噪

`Stop` 每个回合都触发，包括你在旁边正常交互的短回合。嫌吵可在
`~/.claude/notify.env` 设 `NOTIFY_ON_STOP=0`，只保留"待审批 / 等输入"两类通知 ——
`idle_prompt` 本身就意味着"Claude 停了 60 秒没人理"，天然等价于"你不在电脑前"。

## Windows (Git Bash) 说明

- Telegram / Discord 通知完全可用；桌面弹窗目前仅 macOS（`DESKTOP_NOTIFY` 在
  Windows 上自动跳过）。
- 行尾三层防护：`.gitattributes` 钉住模板为 LF、`install.sh` 生成 `notify.env`
  时去 `\r`、`notify.sh` 加载时再去一次 —— 即使用 Windows 编辑器把
  `notify.env` 存成 CRLF 也不会污染 token。
- `chmod 600` 在 NTFS 上只是尽力而为（实际权限由 Windows ACL 管理，文件在你的
  用户目录下默认其他用户不可读）。

## 手工测试

```bash
echo '{"hook_event_name":"Notification","notification_type":"permission_prompt","cwd":"'$PWD'"}' | bash notify.sh
echo '{"hook_event_name":"Stop","last_assistant_message":"测试消息","cwd":"'$PWD'"}' | bash notify.sh
```

配置了渠道的话，手机应立刻收到两条通知。在 Claude Code 里用 `/hooks`
确认 `Notification` 和 `Stop` 已注册。
