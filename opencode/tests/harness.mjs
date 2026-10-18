// Lightweight driver for opencode/notify.ts. Mocks spawn so no notification is sent.
// Usage: node --experimental-test-module-mocks --experimental-strip-types harness.mjs <scenario>

import { mock } from "node:test"
import assert from "node:assert/strict"

const sends = []
mock.module("node:child_process", {
  namedExports: {
    spawn(_cmd, args) {
      const child = {
        unref() {},
        kill() {},
        stdin: {
          end(body) {
            sends.push({
              kind: args[1],
              project: args[2],
              agent: args[3],
              body: body ?? "",
              script: args[0],
            })
          },
        },
        on(ev, fn) {
          if (ev === "exit") queueMicrotask(() => fn(0))
          return child
        },
      }
      return child
    },
  },
})

const plugin = (await import("../notify.ts")).default

function kinds() {
  return sends.map((item) => item.kind)
}

function assertPermission(count) {
  assert.equal(sends.length, count, JSON.stringify(sends))
  for (const item of sends) {
    assert.equal(item.kind, "permission")
    assert.equal(item.project, "demo")
    assert.equal(item.agent, "OpenCode")
    assert.equal(item.body, "")
    assert.match(item.script, /send\.sh$/)
  }
}

async function v1Hooks() {
  return plugin.server({ directory: "/work/demo" })
}

async function scenarioEventOnly() {
  const hooks = await v1Hooks()
  await hooks.event({
    event: {
      id: "evt_bus",
      type: "permission.asked",
      properties: { id: "per_1", sessionID: "ses_1", permission: "bash" },
    },
  })
  assertPermission(1)
}

async function scenarioHookOnly() {
  const hooks = await v1Hooks()
  await hooks["permission.ask"]({ id: "per_old", sessionID: "ses_1" }, { status: "ask" })
  assertPermission(1)
}

async function scenarioHookThenEvent() {
  const hooks = await v1Hooks()
  await hooks["permission.ask"]({ id: "per_both" }, { status: "ask" })
  await hooks.event({
    event: { type: "permission.asked", properties: { id: "per_both" } },
  })
  assertPermission(1)
}

async function scenarioEventThenHook() {
  const hooks = await v1Hooks()
  await hooks.event({
    event: { type: "permission.asked", data: { id: "per_both" } },
  })
  await hooks["permission.ask"]({ id: "per_both" }, { status: "ask" })
  assertPermission(1)
}

async function scenarioDistinctIds() {
  const hooks = await v1Hooks()
  await hooks.event({ event: { type: "permission.asked", properties: { id: "per_a" } } })
  await hooks.event({ event: { type: "permission.asked", properties: { id: "per_b" } } })
  assertPermission(2)
}

async function scenarioNoIdCollapses() {
  const hooks = await v1Hooks()
  await hooks.event({ event: { type: "permission.asked", properties: {} } })
  await hooks["permission.ask"]({}, { status: "ask" })
  assertPermission(1)
}

async function scenarioIdleAndIgnoreReply() {
  const hooks = await v1Hooks()
  await hooks.event({ event: { type: "session.idle" } })
  await hooks.event({ event: { type: "permission.replied", properties: { id: "per_x" } } })
  assert.deepEqual(kinds(), ["stop"])
  assert.equal(sends[0].project, "demo")
  assert.equal(sends[0].agent, "OpenCode")
}

function sessionCtx(info, events) {
  let resolveFinished
  const finished = new Promise((resolve) => {
    resolveFinished = resolve
  })
  return {
    finished,
    ctx: {
      location: { directory: "/work/demo" },
      session: {
        async get() {
          return info
        },
        async context() {
          return []
        },
      },
      event: {
        subscribe() {
          return (async function* () {
            for (const event of events) yield event
            resolveFinished()
          })()
        },
      },
    },
  }
}

async function scenarioV2Permission() {
  const { ctx, finished } = sessionCtx(
    { location: { directory: "/work/demo" } },
    [{ type: "permission.asked", data: { sessionID: "ses_1", id: "per_v2" } }],
  )
  await plugin.setup(ctx)
  await finished
  assertPermission(1)
  const hooks = await plugin.server({ directory: "/work/demo" })
  await hooks["permission.ask"]({ id: "per_v2" }, { status: "ask" })
  await hooks.event({ event: { type: "permission.asked", properties: { id: "per_other" } } })
  assertPermission(1)
}

async function scenarioV2SkipsSubagent() {
  const { ctx, finished } = sessionCtx(
    { parentID: "ses_parent", location: { directory: "/work/demo" } },
    [{ type: "permission.asked", data: { sessionID: "ses_child", id: "per_sub" } }],
  )
  await plugin.setup(ctx)
  await finished
  assert.deepEqual(kinds(), [])
}

async function scenarioV2StillStops() {
  const { ctx, finished } = sessionCtx(
    { location: { directory: "/work/demo" } },
    [{ type: "session.execution.succeeded", data: { sessionID: "ses_1" } }],
  )
  await plugin.setup(ctx)
  await finished
  assert.deepEqual(kinds(), ["stop"])
}

async function scenarioIncompleteSetupStaysV1() {
  await plugin.setup({})
  const hooks = await v1Hooks()
  await hooks.event({ event: { type: "permission.asked", properties: { id: "per_v1" } } })
  assertPermission(1)
}

const scenarios = {
  event_only: scenarioEventOnly,
  hook_only: scenarioHookOnly,
  hook_then_event: scenarioHookThenEvent,
  event_then_hook: scenarioEventThenHook,
  distinct_ids: scenarioDistinctIds,
  no_id_collapses: scenarioNoIdCollapses,
  idle_and_ignore_reply: scenarioIdleAndIgnoreReply,
  v2_permission: scenarioV2Permission,
  v2_skips_subagent: scenarioV2SkipsSubagent,
  v2_still_stops: scenarioV2StillStops,
  incomplete_setup_stays_v1: scenarioIncompleteSetupStaysV1,
}

const name = process.argv[2]
const scenario = scenarios[name]
if (!scenario) {
  console.error("unknown scenario: " + name)
  process.exit(2)
}
await scenario()
console.log(name + " ok")
