# statusline — Grok 两行状态栏

Grok Build 把 JSON 写到这个脚本的 stdin，把 stdout 画在底部状态栏（最多 5 行）。
安装后 `~/.grok/config.toml` 里是：

```toml
[ui.status_line]
type = "command"
command = "bash '/绝对路径/grok/statusline/statusline.sh'"
```

Windows 上 `command` 只是 `~/.grok/coding_agents_env-statusline.cmd` 的绝对路径，
没有引号，也没有参数。Grok 把这一整段当成程序名来启动。引号或前导 `&` 会留在
文件名里，Windows 返回 os error 123。这个 `.cmd` 再调用 Git Bash 执行上面的
脚本。Hook 命令不加 `&`，由 Grok 自己补。

`git pull` 后脚本立即生效。`[ui.status_line]` 在 Grok 启动时读取，改表或刚安装
之后要重启一次。仓库内的 `.grok/config.toml` 不能设置这一项。

```
Grok 4.7 (effort:high) | coding_agents_env | git:main@linked
ctx ████░░░░░░ 42% | $1.23
```

| 段 | 来源 | 缺失时 |
|---|---|---|
| 模型 | `model.display_name` | 不显示 |
| effort | `effort.level` | 不显示，没有配置文件回退 |
| 目录 | `workspace.current_dir`，否则 `cwd`，只取目录名 | 不显示 |
| 分支 | `workspace.branch` | 不显示。不调用 `git` |
| worktree | `workspace.git_worktree`，否则 `worktree.name` | 不显示。有分支时写成 `git:main@name`，否则 `wt:name` |
| context | `context_window.used_percentage` | 整段隐藏。`0` 会显示 |
| 费用 | `cost.total_cost_usd` | 低于 $0.005 或缺失时隐藏，缺失不当作 `$0` |

进度条 10 格。低于 60% 绿，60% 到自动压缩阈值前黄，达到
`context_window.auto_compact_threshold_percent`（没有则 80）起红。字符用
`printf` 八进制输出，避开 bash 3.2 拼接多字节字符时丢字节的问题。

没有可显示的字段时脚本不输出并以 0 退出，Grok 会收起这一行。

不显示订阅配额、脏文件、回合计时、会话名、版本。不读 `notify.env`，不联网。
不写 `refresh_interval`。用户已有的 `padding` 和 `refresh_interval` 重装时保留。

## 冒烟

```bash
echo '{"model":{"display_name":"Grok 4.7"},"effort":{"level":"high"},"workspace":{"current_dir":"'$HOME'","branch":"main"},"context_window":{"used_percentage":42},"cost":{"total_cost_usd":1.23}}' | bash statusline.sh
```
