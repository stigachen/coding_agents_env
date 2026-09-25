// OpenCode 通知插件（coding_agents_env）。
//
// 只做一件事：把 OpenCode 的事件翻译成 lib/send.sh 的调用（kind / project / agent），
// 开关、措辞、前台静音、渠道推送全在 send.sh。IM token 只在 send.sh 进程里加载，
// 本插件不读 notify.env。
//
// 加载方式：opencode/install.sh 在 ~/.config/opencode/plugins/ 生成一个一行的
// 转发文件 `coding_agents_env.ts`（export 本文件的绝对路径），真正的代码留在仓库里，
// git pull 即生效。
//
// 兼容两代插件 API（同一份定义两种 loader 都认）：
//   - v2（OpenCode 2.x）：setup(ctx)，用 ctx.event.subscribe() 收服务端事件。
//     回合结束 = session.execution.succeeded / failed；等审批 = permission.asked；
//     等你回答问题（form）= form.created。
//     子会话（subagent，info.parentID 非空）和别的项目目录的会话一律跳过
//     （全局插件会给每个打开的项目目录各起一个实例，而事件流是服务端全局的，
//     不过滤会重复推送）。
//   注意：插件跑在 OpenCode 的后台服务进程里，不是你终端里的进程，所以 send.sh
//   的"终端聚焦则静音"对 OpenCode 判不准（祖先进程链里没有当前终端），基本会
//   照常推送。桌面级的"窗口在前台就不提醒"请用 OpenCode 自带的 attention 设置。
//   - v1（旧版）：server() 返回 hooks 对象，session.idle → stop，permission.ask → permission。
//     v2 已激活时 v1 的处理函数直接返回，避免重复推送。

import { spawn } from "node:child_process"
import { appendFileSync, realpathSync } from "node:fs"
import { homedir } from "node:os"
import { basename, dirname, join } from "node:path"

const HERE = dirname(realpathSync(import.meta.path))
const SEND = join(HERE, "..", "lib", "send.sh")
const AGENT = "OpenCode"

let v2Active = false

// 排障：NOTIFY_DEBUG=1（服务进程的环境变量）时把插件侧的判定写进和 send.sh 同一个
// 日志 ~/.claude/notify-debug.log。插件跑在后台服务进程里，console 输出看不到
function dbg(msg: string): void {
  if (process.env.NOTIFY_DEBUG !== "1") return
  try {
    const dir = process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude")
    const d = new Date()
    const ts = new Date(d.getTime() - d.getTimezoneOffset() * 60_000).toISOString().replace("T", " ").slice(0, 19) // 本地时间，和 send.sh 的日志对齐
    appendFileSync(join(dir, "notify-debug.log"), ts + " opencode-plugin: " + msg + "\n")
  } catch {}
}

function send(kind: string, directory: string | undefined, body: string): void {
  const project = directory ? basename(directory.replace(/[\\/]+$/, "")) : "unknown"
  try {
    // detached + unref：宿主进程退出（比如 opencode run 结束即销毁的私有服务）时
    // 不连带杀掉正在推送的 send.sh
    const child = spawn("bash", [SEND, kind, project, AGENT], {
      stdio: ["pipe", "ignore", "ignore"],
      env: process.env,
      detached: true,
    })
    child.unref()
    child.on("error", (e) => dbg("spawn error: " + String(e)))
    dbg("send kind=" + kind + " project=" + project)
    // 兜底：send.sh 里 curl 自带超时，这里只是防止极端情况下挂住
    const timer = setTimeout(() => { try { child.kill() } catch {} }, 30_000)
    timer.unref?.()
    child.on("exit", () => clearTimeout(timer))
    child.stdin?.end(body)
  } catch {
    // 通知失败不能影响 OpenCode
  }
}

function lastAssistantText(messages: any[]): string {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i]
    if (m?.type !== "assistant" && m?.role !== "assistant") continue
    const parts = Array.isArray(m.content) ? m.content : Array.isArray(m.parts) ? m.parts : []
    const text = parts.filter((p: any) => p?.type === "text" && typeof p.text === "string").map((p: any) => p.text).join("\n").trim()
    if (text) return text
  }
  return ""
}

// ---- v2 ----
async function setup(ctx: any) {
  if (!ctx?.session || !ctx?.event) { dbg("setup: v2 ctx incomplete, skip"); return } // v1 宿主也会调一次 setup，但没有这些能力
  v2Active = true
  const directory: string | undefined = ctx.location?.directory
  dbg("setup: v2 active, directory=" + directory)
  const controller = new AbortController()
  const owned = new Map<string, boolean>() // sessionID → 是否本项目的顶层会话

  async function isOwned(sessionID: string): Promise<boolean> {
    const cached = owned.get(sessionID)
    if (cached !== undefined) return cached
    const info = await ctx.session.get({ sessionID }).catch(() => null)
    const ok = !!info && !info.parentID && (!directory || !info.location?.directory || info.location.directory === directory)
    dbg("session " + sessionID + " owned=" + ok + " parentID=" + (info?.parentID ?? "") + " dir=" + (info?.location?.directory ?? ""))
    owned.set(sessionID, ok)
    return ok
  }

  async function handle(event: any) {
    const data = (event?.data ?? {}) as Record<string, any>
    const sessionID: unknown = data.sessionID ?? data.form?.sessionID
    if (typeof sessionID !== "string") return
    dbg("event " + event.type + " session=" + sessionID)
    if (event.type === "session.deleted") { owned.delete(sessionID); return }
    const dir = directory ?? event.location?.directory
    switch (event.type) {
      case "session.execution.succeeded": {
        if (!(await isOwned(sessionID))) return
        let last = ""
        try { last = lastAssistantText(await ctx.session.context({ sessionID })) } catch {}
        send("stop", dir, last)
        break
      }
      case "session.execution.failed":
        if (!(await isOwned(sessionID))) return
        send("other", dir, "执行失败" + (data.error?.message ? "：" + String(data.error.message).slice(0, 120) : ""))
        break
      case "permission.asked":
        if (!(await isOwned(sessionID))) return
        send("permission", dir, "")
        break
      case "form.created": // OpenCode 在等你回答一个问题
        if (!(await isOwned(sessionID))) return
        send("idle", dir, "")
        break
    }
  }

  async function consume() {
    for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
      if (controller.signal.aborted) break
      // 单个事件处理出错不能让整个订阅循环退出
      try { await handle(event) } catch {}
    }
  }
  void consume().catch((error: unknown) => {
    if (!controller.signal.aborted) { dbg("subscription failed: " + String(error)); console.error("coding_agents_env: OpenCode event subscription failed", error) }
  })
  return () => controller.abort()
}

// ---- v1 ----
const server = async ({ directory }: any) => ({
  event: async ({ event }: any) => {
    if (v2Active) return
    if (event?.type === "session.idle") send("stop", directory, "")
  },
  "permission.ask": async () => {
    if (v2Active) return
    send("permission", directory, "")
  },
})

export default { id: "coding-agents-env", server, setup }
