// Generated into Pi and OMP user extension folders by Noturcode.
// Keep this file package-neutral. Both harnesses load it without extra dependencies.
import { existsSync } from "node:fs"
import { spawn } from "node:child_process"
import { homedir } from "node:os"
import { basename, join } from "node:path"

const source = "__NOTURCODE_SOURCE__"
const bridge = join(homedir(), "Library/Application Support/Noturcode/bin/noturcode-bridge")
let deliveryQueue = Promise.resolve()

function clean(value) {
  if (typeof value !== "string") return undefined
  const text = value.trim()
  return text.length > 0 ? text : undefined
}

function contentText(content) {
  if (typeof content === "string") return content
  if (!Array.isArray(content)) return ""
  return content
    .filter((block) => block && block.type === "text" && typeof block.text === "string")
    .map((block) => block.text)
    .join("\n")
}

function currentModel(ctx) {
  const selected = ctx.model ?? ctx.models?.current?.()
  if (selected) {
    return { provider: clean(selected.provider), model: clean(selected.id) }
  }
  const branch = ctx.sessionManager.getBranch?.() ?? []
  for (const entry of [...branch].reverse()) {
    if (entry?.type !== "model_change") continue
    const role = entry.role ?? "default"
    if (role !== "default") continue
    if (clean(entry.model)) {
      const separator = entry.model.indexOf("/")
      if (separator > 0) {
        return {
          provider: clean(entry.model.slice(0, separator)),
          model: clean(entry.model.slice(separator + 1)),
        }
      }
      return { provider: undefined, model: clean(entry.model) }
    }
    return { provider: clean(entry.provider), model: clean(entry.modelId) }
  }
  return { provider: undefined, model: undefined }
}

function currentAgentRole(ctx) {
  const branch = ctx.sessionManager.getBranch?.() ?? []
  for (const entry of [...branch].reverse()) {
    if (entry?.type === "session_init") {
      return clean(entry.agent) ?? clean(entry.modelRole)
    }
  }
  return undefined
}

function currentTheme(ctx) {
  const namedTheme = clean(ctx.ui?.theme?.name)
  if (namedTheme) return namedTheme
  const luminance = ctx.ui?.theme?.statusLineLuminance
  if (typeof luminance === "number") return luminance > 0.5 ? "light" : "dark"
  return undefined
}

function sessionTokens(ctx) {
  const branch = ctx.sessionManager.getBranch?.() ?? []
  let total = 0
  for (const entry of branch) {
    const message = entry?.type === "message" ? entry.message : undefined
    if (message?.role !== "assistant" || !message.usage) continue
    const usage = message.usage
    const reported = Number(usage.totalTokens)
    if (Number.isFinite(reported) && reported > 0) {
      total += reported
    } else {
      for (const key of ["input", "output", "cacheRead", "cacheWrite"]) {
        const value = Number(usage[key])
        if (Number.isFinite(value) && value > 0) total += value
      }
    }
  }
  return total > 0 ? total : undefined
}

function latestAssistant(ctx, suppliedMessages) {
  const messages = Array.isArray(suppliedMessages)
    ? suppliedMessages
    : (ctx.sessionManager.getBranch?.() ?? [])
        .filter((entry) => entry?.type === "message")
        .map((entry) => entry.message)
  for (const message of [...messages].reverse()) {
    if (message?.role !== "assistant") continue
    const text = clean(contentText(message.content)) ?? clean(message.errorMessage)
    if (text || message.stopReason) return { text, stopReason: message.stopReason }
  }
  return { text: undefined, stopReason: undefined }
}

function metadata(ctx) {
  const model = currentModel(ctx)
  return {
    session: clean(ctx.sessionManager.getSessionId?.()),
    transcript: clean(ctx.sessionManager.getSessionFile?.()),
    name: clean(piAPI?.getSessionName?.()) ?? (basename(ctx.cwd || homedir()) || source.toUpperCase()),
    cwd: clean(ctx.cwd),
    provider: model.provider,
    model: model.model,
    theme: currentTheme(ctx),
    agentRole: currentAgentRole(ctx),
  }
}

function add(args, option, value, maximum = 2_000) {
  const text = clean(value)
  if (!text) return
  args.push(option, text.slice(0, maximum))
}

function emit(kind, ctx, extra = {}) {
  if (!existsSync(bridge)) return
  const base = metadata(ctx)
  const session = clean(extra.session) ?? base.session
  if (!session) return
  const args = ["emit", "--source", source, "--session", session, "--kind", kind]
  add(args, "--name", extra.name ?? base.name, 120)
  add(args, "--cwd", base.cwd)
  add(args, "--transcript", base.transcript)
  add(args, "--provider", extra.provider ?? base.provider, 160)
  add(args, "--model", extra.model ?? base.model, 240)
  add(args, "--theme", extra.theme ?? base.theme, 120)
  add(args, "--agent-role", extra.agentRole ?? base.agentRole, 120)
  add(args, "--error", extra.error, 240)
  add(args, "--activity", extra.activity, 240)
  add(args, "--subagent", extra.subagent, 240)
  add(args, "--subagent-type", extra.subagentType, 120)
  if (Number.isInteger(extra.sessionTokens) && extra.sessionTokens >= 0) {
    args.push("--session-tokens", String(extra.sessionTokens))
  }
  args.push("--pid", String(process.pid))
  deliveryQueue = deliveryQueue
    .then(() => new Promise((resolve) => {
      try {
        const child = spawn(bridge, args, { stdio: "ignore" })
        child.once("exit", resolve)
        child.once("error", resolve)
      } catch (_) {
        resolve()
      }
    }))
    .catch(() => {})
  return deliveryQueue
}

function agentTool(event) {
  const name = String(event?.toolName ?? "")
  return /(^|[:._-])(task|agent|subagent|spawn-agent|spawn_agent|delegate|vibe)($|[:._-])/i.test(name)
}

function questionTool(event) {
  return /(ask|question|request_user_input|elicitation)/i.test(String(event?.toolName ?? ""))
}

function agentType(event) {
  const args = event?.args && typeof event.args === "object" ? event.args : {}
  return clean(args.agent) ?? clean(args.role) ?? clean(event?.toolName) ?? "agent"
}

let piAPI

export default function noturcode(pi) {
  piAPI = pi

  pi.on("session_start", async (_event, ctx) => {
    emit("connect", ctx)
  })

  pi.on("before_agent_start", async (event, ctx) => {
    emit("promptSubmitted", ctx, { activity: "thinking" })
  })

  pi.on("agent_start", async (_event, ctx) => {
    emit("activityStarted", ctx, { activity: "thinking" })
  })

  const complete = (event, ctx) => {
    const assistant = latestAssistant(ctx, event?.messages)
    const tokens = sessionTokens(ctx)
    if (assistant.stopReason === "error") {
      emit("failed", ctx, { error: "The model reported an error.", sessionTokens: tokens })
    } else if (assistant.stopReason === "aborted") {
      emit("turnInterrupted", ctx, { sessionTokens: tokens })
    } else {
      emit("responseCompleted", ctx, { sessionTokens: tokens })
    }
  }

  if (source === "pi") {
    pi.on("agent_settled", async (event, ctx) => complete(event, ctx))
    pi.on("model_select", async (event, ctx) => {
      emit("metadataUpdated", ctx, {
        provider: event.model?.provider,
        model: event.model?.id,
      })
    })
    pi.on("session_info_changed", async (event, ctx) => {
      emit("metadataUpdated", ctx, { name: event.name })
    })
  } else {
    pi.on("agent_end", async (event, ctx) => {
      ctx.setTimeout(() => {
        if (ctx.isIdle()) complete(event, ctx)
      }, 25)
    })
  }

  pi.on("tool_execution_start", async (event, ctx) => {
    if (agentTool(event)) {
      emit("subagentStarted", ctx, {
        subagent: event.toolCallId,
        subagentType: agentType(event),
        activity: "working",
      })
    } else if (questionTool(event)) {
      emit("askingYou", ctx, { activity: "waiting on your answer" })
    } else {
      emit("activityStarted", ctx, { activity: event.toolName ?? "Tool" })
    }
  })

  pi.on("tool_execution_end", async (event, ctx) => {
    if (agentTool(event)) {
      emit(event.isError ? "subagentFailed" : "subagentCompleted", ctx, {
        subagent: event.toolCallId,
        subagentType: agentType(event),
        error: event.isError ? `${event.toolName ?? "Agent"} failed` : undefined,
      })
    } else {
      emit("activityFinished", ctx, { activity: event.toolName ?? "Tool" })
    }
  })

  pi.on("session_shutdown", async (event, ctx) => {
    if (event.reason !== "reload") await emit("sessionEnded", ctx)
    else await deliveryQueue
  })

  pi.registerCommand("nc", {
    description: "Name or disconnect this Noturcode session",
    handler: async (argumentsText, ctx) => {
      const value = clean(argumentsText)
      if (!value) {
        ctx.ui?.notify?.("Use /nc <name> or /nc stop", "info")
        return
      }
      if (value.toLowerCase() === "stop") {
        await emit("disconnect", ctx)
        return
      }
      await Promise.resolve(pi.setSessionName?.(value))
      await emit("metadataUpdated", ctx, { name: value })
    },
  })
}
