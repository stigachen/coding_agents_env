# codex — Codex CLI

## 通知：`hooks/notify.sh`

Codex 读 `~/.codex/hooks.json`，格式和事件名与 Claude Code 的 hooks 同构。
`notify.sh` 是 `Stop` / `PermissionRequest` 两个事件的入口，只把 Codex 从 stdin
传来的事件 JSON（`hook_event_name`、`cwd`、`last_assistant_message`、`tool_name`
等，snake_case）翻译成 [`lib/send.sh`](../lib/README.md) 的调用；开关、措辞、
前台静音、渠道推送全在 `send.sh`。

| Codex 事件 | `send.sh` kind | 说明 |
|---|---|---|
| `Stop`（回合结束，附最后回复摘要） | `stop` | |
| `PermissionRequest`（进入审批流程之前） | `permission` | 已确认自动审核的 shell / 文件修改请求不通知；其他请求照常通知。本脚本不输出审批决策 |

Codex 没有 Claude 那种"停下 60 秒没人理"的 idle 事件，所以这里没有 `idle`。
hook 退出非 0 或超时只会在 Codex 的 hook 列表里标一条 Failed，不影响 Codex 运行。

### “帮我批准”模式下的审批通知

`PermissionRequest` 不代表已经弹出人工审批框：自动审核或其他 hook 可以接手
请求。因此仅凭这个事件就推送“在等你批准”会产生误报。

适配层利用 hook 的 `transcript_path` 和 `turn_id`，读取**当前回合**的
`turn_context.approvals_reviewer`。对 `Bash` / `apply_patch`，确认是
`auto_review` 时不通知，`user` 时保留通知。无需把 `CODEX_NOTIFY_ON_PERMISSION`
设为 0；既有通知开关仍由 `lib/send.sh` 处理，任务完成通知不受影响。

这是有范围的兼容处理，不是“人工弹窗已出现”的可靠事件：

- 应用/MCP 可单独指定 reviewer，所以这些工具不按会话模式过滤。
- 只读 transcript 最后 2 MiB。回合未落盘、不在读取范围内、文件不可读、字段
  缺失或不认识时，一律保留通知，不从全局配置或其他回合猜测。
- transcript 格式不是稳定接口，升级后可能恢复误报；其他 hook 直接批准也仍
  可能导致误报。自动审核拒绝后的用户沟通不属于这条审批通知链路。
- 官方 app-server 有 `item/commandExecution/requestApproval` 等客户端审批协议，
  但不是能直接注册到 `hooks.json` 的通知 hook。

参考：[Hooks](https://learn.chatgpt.com/docs/hooks)、
[Auto-review](https://learn.chatgpt.com/docs/sandboxing/auto-review)、
[应用审核配置](https://learn.chatgpt.com/docs/config-file/config-reference)。

### Codex 的 hook 信任机制

Codex 只执行"已信任"的 hook：每个 handler 按
`{event_name, matcher?, hooks:[归一化后的 handler]}` 的 canonical JSON 算 sha256，
和 `~/.codex/config.toml` 里
`[hooks.state."<hooks.json 路径>:<事件小写>:<组序号>:<handler 序号>"] trusted_hash`
比对；没有或不一致的 hook 在 TUI 里要 `/hooks` 逐个审核，`codex exec` 模式下
直接跳过。`install.sh` 按同一算法预先算好写进 config.toml，装完即生效，不用
手工审核。算法出处：`codex-rs/hooks/src/engine/discovery.rs` 的 `hook_hash` 和
`codex-rs/config/src/fingerprint.rs` 的 `version_for_toml`；本机已有的第三方
hook 的 trusted_hash 可作为校验样本（`install.sh` 的做法已用它验证过）。

信任 key 里带组序号：如果以后别的工具在我们前面插了一个 hook 组，序号会变，
Codex 会把我们的 hook 标成未信任——重跑 `install.sh` 即可（它会删掉自己旧的
state 块再按新序号写入）。

`[features] hooks = true` 是 Codex 执行 hook 的总开关，缺失时 `install.sh` 补上；
用户显式设了 `false` 则不动、只提示。

## 状态栏：`tui.toml`

Codex 不支持自定义命令画状态栏，只能从内置项目里选（`[tui] status_line`，
TUI 里 `/statusline` 也是改这个键）。`tui.toml` 里是要写进 `[tui]` 表的行，
`install.sh` 把它们插在 `[tui]` 表头之后，每行末尾带 `# coding_agents_env` 标记，
重跑时按标记替换；`[tui]` 里原有的同名键会被仓库版本接管（会提示）。可选项目
清单见 `tui.toml` 的注释。

## 部署逻辑（`install.sh`）

只增删本仓库自己的条目，其他工具写入的 hook / 配置键一律不动：

1. `hooks.json`：按 `/hooks/notify.sh` 路径特征删掉自家旧条目再追加（旧版仓库
   布局的条目也能识别），其他 hook 原样保留；文件不存在则新建
2. `config.toml`：改写前备份为 `config.toml.bak`。删掉自家的 `[hooks.state."…"]`
   块（key 指向我们的槽位，或 hash 是我们的）和带标记的行，插入 `[tui]` 行和
   `[features] hooks`，末尾追加新的信任块。有 python3 ≥ 3.11 时用 `tomllib`
   校验结果，非法则回滚
3. Windows（Git Bash）：信任 key 里的路径用 `cygpath -w` 转成原生路径，键名改用
   TOML 的 `'…'` 字面字符串（`"…"` 里反斜杠是转义符）；解析 config.toml 时容忍
   CRLF。**未在 Windows 上实测**：Codex 在 Windows 上生成 key 用的路径写法
   （反斜杠、是否带 `\\?\` 前缀）没有验证。若 key 对不上，Codex 只会把这两个
   hook 标成未信任，在 TUI 里 `/hooks` 手动信任一次即可，Codex 会自己写入正确的
   state 块，之后重跑 `install.sh` 也不会覆盖它

## 手工测试

```bash
cd codex/hooks
echo '{"hook_event_name":"Stop","cwd":"'$PWD'","last_assistant_message":"测试"}' | NOTIFY_DRY_RUN=1 bash notify.sh
echo '{"hook_event_name":"PermissionRequest","cwd":"'$PWD'","tool_name":"Bash"}' | NOTIFY_DRY_RUN=1 bash notify.sh
```

端到端：装好后跑一轮 `codex exec "Reply with exactly the single word: pong"`，
手机应收到"Codex 任务完成"（终端聚焦时会被静音，可 `NOTIFY_SKIP_WHEN_FOCUSED=0`
前缀）。TUI 里 `/hooks` 应显示两条已信任的 hook。

审批模式过滤回归测试（隔离配置，仅 dry-run，不发送通知）：

```bash
python3 codex/tests/test_notify.py
```
