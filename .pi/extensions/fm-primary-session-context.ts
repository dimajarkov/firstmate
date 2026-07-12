// Firstmate-owned Pi equivalent of the supported Codex SessionStart CLI hooks.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const CONTEXT_TYPE = "firstmate-axi-session-context";
const COMMAND_TIMEOUT_MS = 10_000;
const MAX_TOOL_BYTES = 12_000;
const MAX_TOOL_LINES = 160;

const CONTEXT_COMMANDS = [
  "tasks-axi",
  "gh-axi",
  "lavish-axi",
  "chrome-devtools-axi",
] as const;

type ExecResult = {
  stdout?: string;
  stderr?: string;
  code?: number | null;
  killed?: boolean;
};

function cleanOutput(value: string): string {
  return value
    .replace(/\x1b\[[0-?]*[ -\/]*[@-~]/g, "")
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, "")
    .replace(/\r\n?/g, "\n")
    .trim();
}

export function truncateContext(value: string): { text: string; truncated: boolean } {
  const lines = cleanOutput(value).split("\n");
  let text = lines.slice(0, MAX_TOOL_LINES).join("\n");
  let truncated = lines.length > MAX_TOOL_LINES;
  const bytes = Buffer.from(text);
  if (bytes.byteLength > MAX_TOOL_BYTES) {
    text = bytes.subarray(0, MAX_TOOL_BYTES).toString("utf8").replace(/\ufffd$/, "");
    truncated = true;
  }
  return { text, truncated };
}

function sessionHasContext(ctx: any): boolean {
  return ctx.sessionManager.getBranch().some((entry: any) =>
    entry?.type === "message" && entry?.message?.customType === CONTEXT_TYPE,
  );
}

async function commandContext(pi: ExtensionAPI, command: string): Promise<string> {
  let result: ExecResult;
  try {
    result = await pi.exec(command, [], { timeout: COMMAND_TIMEOUT_MS });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return `### ${command}\nUnavailable: ${cleanOutput(message) || "command failed"}`;
  }

  const combined = [result.stdout, result.stderr].filter(Boolean).join("\n");
  const output = truncateContext(combined);
  if (result.killed) return `### ${command}\nUnavailable: timed out after ${COMMAND_TIMEOUT_MS}ms`;
  if (result.code !== 0) {
    const detail = output.text ? `\n${output.text}` : "";
    return `### ${command}\nUnavailable: exited ${result.code ?? "without a status"}${detail}`;
  }
  if (!output.text) return `### ${command}\nAvailable, but returned no startup guidance.`;
  return `### ${command}\n${output.text}${output.truncated ? "\n[Startup guidance truncated by Firstmate.]" : ""}`;
}

export default function (pi: ExtensionAPI) {
  let context = "";
  let injected = false;

  pi.on("session_start", async (_event, ctx) => {
    injected = sessionHasContext(ctx);
    context = "";
    if (injected) return;

    const blocks: string[] = [];
    for (const command of CONTEXT_COMMANDS) {
      blocks.push(await commandContext(pi, command));
    }
    context = [
      "Firstmate Pi startup context",
      "These are CLI guidance blocks, not Pi tool registrations or MCP servers.",
      "Call the named programs through Pi's bash tool.",
      ...blocks,
      "### Related interfaces",
      "- quota-axi is a read-only, on-demand quota CLI with no SessionStart contract; use `quota-axi --help` before calling it.",
      "- axi is the shared SDK/runtime used by the *-axi CLIs and does not expose an `axi` executable.",
      "- treehouse is an independent worktree lifecycle CLI; use `treehouse --help` and follow Firstmate's lifecycle rules.",
    ].join("\n\n");
  });

  pi.on("before_agent_start", () => {
    if (injected || !context) return;
    injected = true;
    return {
      message: {
        customType: CONTEXT_TYPE,
        content: context,
        display: false,
      },
    };
  });

  pi.on("session_shutdown", () => {
    context = "";
    injected = false;
  });
}
