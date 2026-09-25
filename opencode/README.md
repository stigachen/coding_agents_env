# opencode — OpenCode

## 通知：`notify.ts`

OpenCode 没有 shell 命令型 hook，事件只能通过插件拿。`notify.ts` 是一个几十行的
插件，只把事件翻译成 [`lib/send.sh`](../lib/README.md) 的调用；开关、措辞、
前台静音、渠道推送全在 `send.sh`，IM token 也只在 `send.sh` 进程里加载。

| OpenCode 事件 | `send.sh` kind | 说明 |
|---|---|---|
| `session.execution.succeeded`（回合结束） | `stop` | 摘要取 `ctx.session.context()` 里最后一条 assistant 文本 |
| `session.execution.failed` | `other` | 正文"执行失败" + 错误信息 |
| `permission.asked`（等审批） | `permission` | 只通知，不替你做决定 |

子会话（subagent，`info.parentID` 非空）和别的项目目录的会话一律跳过，
不会为 subagent 的每一步推一条。OpenCode 没有 Claude 那种 idle 事件，所以
没有 `idle`。

插件同时带 v1（`server()` 返回 hooks 对象，`session.idle` / `permission.ask`）
和 v2（`setup(ctx)` + `ctx.event.subscribe()`，OpenCode 2.x）两代 API 的实现，
两种 loader 都认；v2 激活后 v1 的处理函数直接返回，不会重复推送。

OpenCode 自带的 `attention` 设置（`~/.config/opencode/tui.json`：桌面通知、
提示音，按 permission / question / done / error 分类）是本机偏好，不纳入仓库；
想要桌面提醒直接用它，`DESKTOP_NOTIFY` 对 OpenCode 可留 0。

## 状态栏

OpenCode 的 TUI 状态栏是内置的，只能换主题（`tui.json` 的 `theme`），没有
可配置的状态栏项目，也没有命令钩子。这里没有对应模块。

## 部署逻辑（`install.sh`）

在 `~/.config/opencode/plugins/` 生成一个转发文件 `coding_agents_env.ts`，内容
只有一行 `export { default } from "<仓库>/opencode/notify.ts"`。真正的代码留在
仓库，git pull 即生效；不用软链是因为 Git Bash 的 `ln -s` 默认是复制。
`plugins/` 目录里其他插件一律不动。OpenCode 会自动加载该目录下所有 `.ts`，
`tui.json` 的 `plugin_enabled` 可以按 id（`coding-agents-env`）关掉。

## Windows（Git Bash）说明

插件用 `spawn` 起 `send.sh`，Windows 上 PATH 里的 `bash` 往往是 WSL 的启动器，
所以插件按顺序找：`CLAUDE_CODE_GIT_BASH_PATH` 环境变量、
`C:\Program Files\Git\bin\bash.exe`、`usr\bin\bash.exe`、
`%LOCALAPPDATA%\Programs\Git\bin\bash.exe`，都没有才退回 `bash`。传给
Git Bash 的脚本路径用正斜杠。转发文件里的 import 路径由 `install.sh` 用
`cygpath -m` 生成（`C:/Users/...`）。**未在 Windows 上实测**；排障时开
`NOTIFY_DEBUG=1`，日志里 `bash=… send=…` 一行能看到实际用的路径。

## 手工测试

插件跑在 OpenCode 的服务进程里，看不到它的 stdout；用调试日志：`NOTIFY_DEBUG=1`
时插件自己（`opencode-plugin:` 前缀：setup、收到的事件、会话归属判定、spawn）
和 `send.sh` 都写 `~/.claude/notify-debug.log`。

```bash
NOTIFY_DEBUG=1 NOTIFY_SKIP_WHEN_FOCUSED=0 opencode run --standalone "Reply with exactly the single word: pong"
grep -E 'opencode-plugin: send|agent=OpenCode' ~/.claude/notify-debug.log | tail -2
```

`--standalone` 让这次运行起一个私有服务进程（继承当前 shell 的环境变量，所以上面
的临时变量才生效）；平时的后台服务进程读不到这些临时变量，改 `notify.env` 即可。
不加 `--standalone` 走后台服务，就是日常的真实路径，手机应收到"OpenCode 任务完成"。
后台服务会监视插件目录，改了 `notify.ts` 会热加载，不用重启。

已知：`opencode run --standalone` 偶尔在服务启动阶段卡住（插件加载之前，
与本插件无关），杀掉重跑即可。
