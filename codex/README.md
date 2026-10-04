# codex — Codex CLI

## 通知：`hooks/notify.sh`

Codex 读 `~/.codex/hooks.json`，格式和事件名与 Claude Code 的 hooks 同构。
`notify.sh` 是 `Stop` / `PermissionRequest` 两个事件的入口，只把 Codex 从 stdin
传来的事件 JSON（`hook_event_name`、`cwd`、`last_assistant_message`、`tool_name`
等，snake_case）翻译成 [`lib/send.sh`](../lib/README.md) 的调用；开关、措辞、
前台静音、渠道推送全在 `send.sh`。

| Codex 事件 | `send.sh` kind | 说明 |
|---|---|---|
| `Stop`（回合结束，附最后回复摘要） | `stop` / `stop_without_transcript` | 显式 `transcript_path: null` 默认静音，其余照常通知 |
| `PermissionRequest`（进入审批流程之前） | `permission` / `permission_without_transcript` | 显式 `transcript_path: null` 默认静音；有记录路径时仍只过滤已确认自动审核的 shell / 文件修改。本脚本不输出审批决策 |

Codex 没有 Claude 那种"停下 60 秒没人理"的 idle 事件，所以这里没有 `idle`。
hook 退出非 0 或超时只会在 Codex 的 hook 列表里标一条 Failed，不影响 Codex 运行。

### 未提供会话记录路径的完成通知

Codex 桌面端会用临时会话在后台生成项目建议，即使结果是 `{"suggestions":[]}`
也会触发 `Stop`。这类会话没有持久记录，hook 收到 `transcript_path: null`。
适配层把**字段存在且值严格为 JSON null** 的 `Stop` 翻译成
`stop_without_transcript`，通知内核默认静音；不检查回复正文、模型或审批模式。
字段缺失、空字符串、非空路径但文件不存在/不可读时，仍按普通 `stop` 通知。

**这个条件不能精确区分后台任务与用户任务，也不证明会话没有远程记录。** Codex 0.160.0 的 shell hook
输入没有桌面端的 `threadSource` / `turnTrigger` 标记。手动运行
`codex exec --ephemeral`、临时侧聊、没有本地 transcript 路径的远程存储会话，
以及 Codex 读取记录路径出错而返回 null 的情况，也会被静音。这是本过滤的
明确范围。完成通知开关本身不影响审批通知，后者由下节的独立开关控制。

需要这些完成通知时，在 `~/.config/coding_agents_env/notify.env` 设置
`CODEX_NOTIFY_ON_STOP_WITHOUT_TRANSCRIPT=1` 即时恢复（后台建议通知也会恢复）。
`NOTIFY_ON_STOP=0` / `CODEX_NOTIFY_ON_STOP=0` 仍可关闭全部完成通知。
旧配置文件没有新增键时也使用默认值 0，无需重新安装。

实现依据（Codex 0.160.0）：[Stop hook 输入字段](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/hooks/src/events/stop.rs#L147-L167)、
[路径为空或读取出错的处理](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/core/src/session/mod.rs#L5071-L5089)、
[远程存储不提供本地路径](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/thread-store/src/live_thread.rs#L406-L420)。

### 未提供会话记录路径的审批通知

后台建议任务还会访问连接的应用，一次运行可能产生多条 `PermissionRequest`，
即使完成通知已静音，也会连续推送“在等你批准”。这类无项目任务的 `cwd` 可为
`/`，因此通知标签显示为 `[/@主机]`；目录名不是过滤条件。

适配层对审批事件使用与完成通知相同的严格 null 判定，映射成
`permission_without_transcript`，由通知内核默认静音，包含 shell、应用/MCP
及其他工具。字段缺失、空字符串、非空路径但文件不存在/不可读时不按这个条件
静音；原有自动审核过滤仍然生效。有记录路径的 MCP 审批通知继续保留。

**这也会静音 `--ephemeral`、临时侧聊、无本地路径的远程会话，以及路径读取
失败返回 null 时的真实人工审批提醒。** 通知静音不代表操作已获批准：脚本不
输出审批决策，任务仍可能停下等待人工确认。需要这些提醒时，在 `notify.env`
设 `CODEX_NOTIFY_ON_PERMISSION_WITHOUT_TRANSCRIPT=1` 即时恢复；后台建议任务的
审批提醒也会恢复。没有新增键的旧配置使用默认值 0。

两个 `_WITHOUT_TRANSCRIPT` 开关相互独立，分别仍受对应的完成/审批总开关
控制；开启审批专属开关不能绕过 `CODEX_NOTIFY_ON_PERMISSION=0`，关闭完成
通知也不会关闭审批通知。Claude Code 和 OpenCode 继续使用普通通知类型，
不会进入这两个新增分类。

### “帮我批准”模式下的审批通知

`PermissionRequest` 不代表已经弹出人工审批框：自动审核或其他 hook 可以接手
请求。因此仅凭这个事件就推送“在等你批准”会产生误报。

适配层利用 hook 的 `transcript_path` 和 `turn_id`，读取**当前回合**的
`turn_context.approvals_reviewer`。对 `Bash` / `apply_patch`，确认是
记录为 `auto_review` 时不通知，`user` 时保留通知。无需把 `CODEX_NOTIFY_ON_PERMISSION`
设为 0；既有通知开关仍由 `lib/send.sh` 处理，任务完成通知不受影响。

这是有范围的兼容处理，不是“人工弹窗已出现”的可靠事件：

- 应用/MCP 可单独指定 reviewer，所以这些工具不按会话模式过滤；显式 null
  的审批通知另由上节的开关控制。
- 只读 transcript 最后 2 MiB。回合未落盘、不在读取范围内、文件不可读、字段
  缺失或不认识时保留通知（显式 null 的路径除外，见上节），不从全局配置或
  其他回合猜测。
- transcript 格式不是稳定接口，升级后可能恢复误报；其他 hook 直接批准也仍
  可能导致误报。自动审核拒绝后的用户沟通不属于这条审批通知链路。
- 官方 app-server 有 `item/commandExecution/requestApproval` 等客户端审批协议，
  但不是能直接注册到 `hooks.json` 的通知 hook。

参考：[Hooks](https://learn.chatgpt.com/docs/hooks)、
[Auto-review](https://learn.chatgpt.com/docs/sandboxing/auto-review)、
[应用审核配置](https://learn.chatgpt.com/docs/config-file/config-reference)。

### Known issue：回合中途切换审核方式可能漏发通知

**同一回合以自动审核（“帮我批准”）开始、中途切回人工审核时，后续真实的
人工审批请求可能没有通知。** Codex 0.159.3 支持通过 `turn/settings/update`
更新实际审核方，但 transcript 的 `turn_context.approvals_reviewer` 可能仍是
回合开始时的 `auto_review`。本脚本据此过滤 `Bash` / `apply_patch` 请求，因而
可能漏发通知；精确匹配 `turn_id` 或取同回合最后一条 context 也无法解决。

反向切换（人工 → 自动）则可能继续发送审批通知。这是已接受、尚未修复的
限制，不代表脚本能实时读取实际审核方。自动审核降噪方案保留，其他已知限制
仍见上文。

规避方式：尽量在回合结束后、下一回合开始前切换审核方式；若必须中途切换，
请同时留意 Codex 界面的审批提示，不要仅依赖推送。任务完成通知不受影响。

依据：[同回合切换 reviewer 的上游测试](https://github.com/openai/codex/blob/rust-v0.159.3/codex-rs/app-server/tests/suite/v2/turn_settings_update.rs#L425-L525)、
[TurnContext 序列化](https://github.com/openai/codex/blob/rust-v0.159.3/codex-rs/core/src/session/turn_context.rs#L777-L786)。

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

审批模式和完成通知过滤回归测试（隔离配置，仅 dry-run，不发送通知）：

```bash
python3 codex/tests/test_notify.py
```
