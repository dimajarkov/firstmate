#!/usr/bin/env bash
# Tests for Pi startup context ordering, isolation, and session lifecycle.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXT="$ROOT/.pi/extensions/fm-primary-session-context.ts"

run_fixture() {
  local scenario=$1
  NODE_NO_WARNINGS=1 SCENARIO="$scenario" EXT="$EXT" node --experimental-strip-types --input-type=module <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const calls = [];
let active = 0;
let maxActive = 0;
const outputs = {
  "tasks-axi": { stdout: "bin: ~/.npm-global/bin/tasks-axi\ndescription: task manager\nin_flight: 0 tasks\u0000", stderr: "", code: 0, killed: false },
  "gh-axi": { stdout: "bin: ~/.npm-global/bin/gh-axi\ndescription: GitHub wrapper\nrepo: owner/name", stderr: "", code: 0, killed: false },
  "lavish-axi": { stdout: "bin: ~/.npm-global/bin/lavish-axi\ndescription: review surface\nsessions[0]:", stderr: "", code: 0, killed: false },
  "chrome-devtools-axi": { stdout: "bin: /path/chrome-devtools-axi.js\ndescription: browser control\nbrowser: no active session", stderr: "", code: 0, killed: false },
};
const pi = {
  on(name, handler) { handlers.set(name, handler); },
  async exec(command, args, options) {
    calls.push({ command, args, options });
    if (process.env.SCENARIO === "concurrent") {
      active += 1;
      maxActive = Math.max(maxActive, active);
      const delay = { "tasks-axi": 40, "gh-axi": 30, "lavish-axi": 20, "chrome-devtools-axi": 10 }[command];
      await new Promise((resolve) => setTimeout(resolve, delay));
      active -= 1;
    }
    if (process.env.SCENARIO === "fail" && command === "gh-axi") throw new Error("missing binary");
    if (process.env.SCENARIO === "timeout" && command === "lavish-axi") return { stdout: "", stderr: "", code: null, killed: true };
    if (process.env.SCENARIO === "truncate" && command === "tasks-axi") return { stdout: "x\n".repeat(300), stderr: "", code: 0, killed: false };
    return outputs[command];
  },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
const existing = process.env.SCENARIO === "existing"
  ? [{ type: "message", message: { customType: "firstmate-axi-session-context" } }]
  : [];
const ctx = { sessionManager: { getBranch: () => existing } };
await handlers.get("session_start")({ reason: "startup" }, ctx);
const first = await handlers.get("before_agent_start")({}, ctx);
const second = await handlers.get("before_agent_start")({}, ctx);

if (process.env.SCENARIO === "existing") {
  if (calls.length !== 0 || first !== undefined) throw new Error("reload duplicated existing session context");
  process.exit(0);
}
if (calls.map((call) => call.command).join(",") !== "tasks-axi,gh-axi,lavish-axi,chrome-devtools-axi") throw new Error("command ordering changed");
if (calls.some((call) => call.options.timeout !== 10000)) throw new Error("command timeout missing");
if (!first?.message?.content || first.message.display !== false) throw new Error("hidden context message missing");
if (second !== undefined) throw new Error("context injected more than once");
if (process.env.SCENARIO === "normal") {
  for (const shape of ["in_flight: 0 tasks", "repo: owner/name", "sessions[0]:", "browser: no active session"]) {
    if (!first.message.content.includes(shape)) throw new Error(`current CLI output shape missing: ${shape}`);
  }
  if (first.message.content.includes("\u0000")) throw new Error("control character reached model context");
}
if (!first.message.content.includes("quota-axi") || !first.message.content.includes("shared SDK/runtime") || !first.message.content.includes("treehouse")) throw new Error("related interface roles missing");
if (process.env.SCENARIO === "fail" && !first.message.content.includes("Unavailable: missing binary")) throw new Error("missing binary was not isolated");
if (process.env.SCENARIO === "timeout" && !first.message.content.includes("timed out after 10000ms")) throw new Error("timeout was not isolated");
if (process.env.SCENARIO === "truncate" && !first.message.content.includes("Startup guidance truncated by Firstmate")) throw new Error("truncation marker missing");
if (process.env.SCENARIO === "concurrent") {
  if (maxActive !== 4) throw new Error(`expected four concurrent probes, observed ${maxActive}`);
  const headings = ["### tasks-axi", "### gh-axi", "### lavish-axi", "### chrome-devtools-axi"];
  const positions = headings.map((heading) => first.message.content.indexOf(heading));
  if (positions.some((position) => position < 0) || positions.some((position, index) => index > 0 && position < positions[index - 1])) throw new Error("concurrent results rendered out of order");
}

await handlers.get("session_shutdown")({ reason: "new" }, ctx);
await handlers.get("session_start")({ reason: "new" }, { sessionManager: { getBranch: () => [] } });
const replacement = await handlers.get("before_agent_start")({}, ctx);
if (!replacement?.message?.content) throw new Error("replacement session did not receive context");
EOF
}

assert_present "$EXT" "tracked Pi session context extension is missing"
run_fixture normal || fail "Pi session context normal lifecycle failed"
run_fixture fail || fail "Pi session context missing-binary isolation failed"
run_fixture timeout || fail "Pi session context timeout isolation failed"
run_fixture truncate || fail "Pi session context truncation failed"
run_fixture concurrent || fail "Pi session context concurrency or deterministic ordering failed"
run_fixture existing || fail "Pi session context reload deduplication failed"
pass "Pi session context is concurrent, ordered, bounded, isolated, and once per session"
