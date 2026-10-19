// TableStudio for OpenCode (V2 plugin API).
//
// One plugin entry gives OpenCode everything the Claude Code, Cursor and Codex plugins give their
// clients, all through the same `scripts/tablestudio-hook`:
//
// - TableStudio's MCP server, registered through the stdio bridge (`mcp-stdio`), which reads the
//   token from the app for every message — nothing to paste, nothing secret in opencode.json.
// - The three skills from `../skills`.
// - The "Database context" note, added to the system prompt of each request.
// - The shell guard, as a permission rule: shell commands that write to production are denied, and
//   writes to other remote databases ask the user, using OpenCode's own approval prompt.
// - The migration reminder, once per session, after the agent edits a migration file.
// - Attribution: each TableStudio tool call is reported with its session id and the
//   conversation's first prompt, so TableStudio's Agent Center can show it under the OpenCode
//   conversation that made it, titled.
//
// Every step fails open: if the hook script errors, OpenCode behaves as if the plugin weren't there.

import { spawn } from "node:child_process"
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync } from "node:fs"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const hookScript = path.join(root, "scripts", "tablestudio-hook")
const MIGRATION_PATH = /(^|\/)(migrations|migrate|alembic\/versions)\/[^/]+|\.prisma$|(^|\/)drizzle\/[^/]*\.sql$/

/** Problems go to ~/Library/Logs/TableStudio/opencode-plugin.log rather than OpenCode's screen. */
function logProblem(step, error) {
  try {
    const dir = path.join(os.homedir(), "Library", "Logs", "TableStudio")
    mkdirSync(dir, { recursive: true })
    appendFileSync(path.join(dir, "opencode-plugin.log"),
      `${new Date().toISOString()} ${step}: ${error?.stack ?? error}\n`)
  } catch {}
}

/** Runs the hook script with a JSON payload on stdin and resolves its stdout ("" on any failure). */
function runHook(args, payload, cwd, timeoutMs = 15000) {
  return new Promise((resolve) => {
    let out = ""
    let settled = false
    const done = (value) => {
      if (settled) return
      settled = true
      resolve(value)
    }
    try {
      const child = spawn("/bin/bash", [hookScript, ...args], { cwd, stdio: ["pipe", "pipe", "ignore"] })
      const timer = setTimeout(() => {
        child.kill()
        done("")
      }, timeoutMs)
      child.stdout.on("data", (chunk) => (out += chunk))
      child.on("error", () => done(""))
      child.on("close", () => {
        clearTimeout(timer)
        done(out)
      })
      child.stdin.on("error", () => {})
      child.stdin.end(JSON.stringify(payload ?? {}))
    } catch {
      done("")
    }
  })
}

function hookOutput(text) {
  try {
    return JSON.parse(text.trim().split("\n").pop() || "{}").hookSpecificOutput ?? {}
  } catch {
    return {}
  }
}

/** The plugin's skills, read from `skills/<name>/SKILL.md`. */
function readSkills() {
  const dir = path.join(root, "skills")
  if (!existsSync(dir)) return []
  return readdirSync(dir).flatMap((name) => {
    const file = path.join(dir, name, "SKILL.md")
    if (!existsSync(file)) return []
    const text = readFileSync(file, "utf8")
    const match = text.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/)
    const front = match ? match[1] : ""
    const field = (key) => front.match(new RegExp(`^${key}:\\s*(.*)$`, "m"))?.[1]?.trim()
    return [{
      id: `tablestudio-${field("name") ?? name}`,
      name: field("name") ?? name,
      description: field("description"),
      path: file,
      content: match ? match[2] : text,
    }]
  })
}

/** The first piece of text in a prompt, whatever shape OpenCode gives it: the conversation's title. */
function promptText(value, depth = 0) {
  if (depth > 6 || value == null) return undefined
  if (typeof value === "string") {
    let text = value.trim()
    // Some OpenCode versions hand over the prompt JSON-encoded: "\"text\"".
    if (text.startsWith('"')) {
      try {
        const parsed = JSON.parse(text)
        if (typeof parsed === "string") text = parsed.trim()
      } catch {
        text = text.replace(/^"+|"+$/g, "").trim()
      }
    }
    return text || undefined
  }
  if (Array.isArray(value)) {
    for (const item of value) {
      const text = promptText(item, depth + 1)
      if (text) return text
    }
    return undefined
  }
  if (typeof value === "object") {
    if (typeof value.text === "string" && value.text.trim()) return promptText(value.text, depth + 1)
    for (const key of ["parts", "content", "prompt", "input"]) {
      const text = promptText(value[key], depth + 1)
      if (text) return text
    }
  }
  return undefined
}

function toolInputPath(input) {
  if (!input || typeof input !== "object") return undefined
  return input.filePath ?? input.file_path ?? input.path
}

export default {
  id: "tablestudio",
  async setup(ctx) {
    const directory = ctx.location?.directory ?? process.cwd()
    const registrations = []
    const register = async (step, promise) => {
      try {
        registrations.push(await promise)
      } catch (error) {
        logProblem(step, error)
      }
    }
    const guarded = (step, callback) => async (input) => {
      try {
        await callback(input)
      } catch (error) {
        logProblem(step, error)
      }
    }

    // TableStudio's MCP server. Left alone when the user already added one by that name.
    await register("mcp", ctx.mcp.transform(guarded("mcp", (mcp) => {
      if (mcp.get("tablestudio")) return
      mcp.set("tablestudio", { type: "local", command: ["/bin/bash", hookScript, "mcp-stdio", "opencode"] })
    })))

    const skills = readSkills()
    await register("skills", ctx.skill.transform(guarded("skills", (editor) => {
      for (const skill of skills) if (!editor.get(skill.id)) editor.add(skill)
    })))

    // The Database context note: worked out once (it reads the repo and TableStudio's settings,
    // and may open TableStudio), then added to every request's system prompt.
    const note = runHook(["session-start", "opencode"], { source: "startup", cwd: directory }, directory)
      .then((text) => hookOutput(text).additionalContext ?? "")
    const reminders = new Map()
    // The first thing asked in each conversation, sent with its TableStudio calls as the title.
    const titles = new Map()
    await register("prompt", ctx.session.hook("prompt", guarded("prompt", (prompt) => {
      if (titles.has(prompt.sessionID)) return
      const text = promptText(prompt.prompt)
      if (text) titles.set(prompt.sessionID, text.split("\n")[0].slice(0, 120))
      // One entry per conversation this OpenCode has seen; the oldest go first.
      while (titles.size > 200) titles.delete(titles.keys().next().value)
    })))
    await register("context", ctx.session.hook("context", guarded("context", async (request) => {
      const text = await note
      if (text && !request.system.some((part) => part?.text === text)) request.system.push({ type: "text", text })
      const pending = reminders.get(request.sessionID)
      if (pending) {
        reminders.delete(request.sessionID)
        request.system.push({ type: "text", text: pending })
      }
    })))

    // Shell guard. OpenCode asks for permission itself, so a write to a remote database gets
    // OpenCode's own approval prompt and a production write is denied outright.
    await register("guard", ctx.permission.hook("evaluate", guarded("guard", async (evaluation) => {
      if (evaluation.action !== "shell") return
      const command = evaluation.metadata?.command ?? evaluation.resources?.[0]
      if (typeof command !== "string" || !command) return
      const decision = hookOutput(await runHook(["guard-shell", "opencode"], {
        tool_input: { command },
        cwd: directory,
        session_id: evaluation.sessionID,
      }, directory, 10000))
      if (decision.permissionDecision === "deny") {
        evaluation.effect = "deny"
        evaluation.message = decision.permissionDecisionReason
      } else if (decision.permissionDecision === "ask" && evaluation.effect !== "deny") {
        evaluation.effect = "ask"
        evaluation.message = decision.permissionDecisionReason
      }
    })))

    // Which conversation is making a TableStudio call, reported before it runs and awaited, so
    // TableStudio knows the chat while the call is in flight: its chosen database (use_database)
    // and the link to its activity. The after-hook below covers versions without this one.
    const reportedBefore = new Set()
    await register("tools-before", ctx.tool.hook("execute.before", guarded("tools-before", async (call) => {
      if (!/tablestudio/i.test(call.tool ?? "")) return
      await runHook(["agent-event", "opencode"], {
        hook_event_name: "before",
        session_id: call.sessionID,
        tool_name: call.tool,
        tool_input: call.input,
        title: titles.get(call.sessionID),
        cwd: directory,
      }, directory, 3000)
      if (call.id) reportedBefore.add(call.id)
      if (reportedBefore.size > 500) reportedBefore.delete(reportedBefore.values().next().value)
    })))

    await register("tools", ctx.tool.hook("execute.after", guarded("tools", async (call) => {
      // Which conversation made this TableStudio call — for the Agent Center. Not awaited.
      if (/tablestudio/i.test(call.tool)) {
        if (call.id && reportedBefore.delete(call.id)) return
        void runHook(["agent-event", "opencode"], {
          session_id: call.sessionID,
          tool_use_id: call.id,
          tool_name: call.tool,
          tool_input: call.input,
          status: call.status,
          title: titles.get(call.sessionID),
          cwd: directory,
        }, directory, 5000)
        return
      }
      // The agent just edited a migration: remind it, once per session, to check it against the
      // real data before calling it done.
      const file = toolInputPath(call.input)
      if (typeof file === "string" && MIGRATION_PATH.test(file)) {
        const context = hookOutput(await runHook(["after-tool", "opencode"], {
          tool_input: { file_path: file },
          cwd: directory,
          session_id: call.sessionID,
        }, directory, 10000)).additionalContext
        if (context) reminders.set(call.sessionID, context)
      }
    })))

    return async () => {
      for (const registration of registrations.splice(0)) {
        try {
          await registration.dispose()
        } catch {}
      }
    }
  },
}
