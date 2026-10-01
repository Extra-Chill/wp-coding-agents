// dm-context-filter.ts — OpenCode plugin for WordPress agent VPSes with Data Machine.
//
// Replaces Kimaki's built-in system prompt on managed installs. Kimaki remains
// the Discord bridge and human coordination surface. Available runtime,
// orchestration, preview, tunnel, and workspace guidance comes from composed
// Data Machine AGENTS.md sections registered by the components present on the
// install.
//
// The replacement prompt is deliberately small. Repository, agent memory,
// scheduling, lab, preview, tunnel, and workspace instructions come from the
// composed Data Machine/AGENTS instruction stack, not from Kimaki's generic CLI
// prompt.
//
// What it removes from chat message injection:
// 1. MEMORY.md injection — Kimaki reads MEMORY.md from the project directory and
//    injects a condensed TOC. Conflicts with Data Machine's own memory files.
// 2. "Update MEMORY.md" time-gap reminder — Redundant with external memory system.
// Total savings depends on the Kimaki version and managed startup flags.
//
// How to use:
//   Add to opencode.json:  "plugin": ["/opt/kimaki-config/plugins/dm-context-filter.ts"]
//   Or place in .opencode/plugins/ in the project root.

/**
 * External dependencies
 */
import type { Plugin } from "@opencode-ai/plugin";

const MANAGED_KIMAKI_SYSTEM_PROMPT = `## Kimaki Discord Bridge

Kimaki connects this OpenCode session to Discord. Treat Discord as the human coordination surface: keep the thread updated, ask the user for files with the native upload tool when needed, upload user-facing artifacts when useful, mention users by Discord ID when action is required, and archive the thread when the user explicitly asks.

## Managed Coding Runtime

Use the composed Data Machine AGENTS.md guidance for the coding runtime, workspace, orchestration, preview, tunnel, and evidence capabilities available on this install.

## Bridge Diagnostics

For Kimaki bridge failures, inspect \$HOME/.kimaki/kimaki.log. The log is reset every time Kimaki restarts, so it only covers the current run.
`;

const fleetContextFilter: Plugin = async () => {
  const systems = new Map<string, Set<string[]>>();
  const parameters = new Map<string, { options: Record<string, any> }>();
  const requestKey = (input: any) => `${input.sessionID ?? ""}:${input.model?.providerID ?? ""}:${input.model?.id ?? ""}`;
  const parameterKey = (input: any) => `${requestKey(input)}:${input.agent ?? ""}:${input.message?.id ?? ""}`;
  const checkSystems = (key: string) => {
    for (const blocks of systems.get(key) ?? []) {
      for (const block of blocks) assertManagedPrompt(block);
    }
  };
  return {
    dispose: async () => { systems.clear(); parameters.clear(); },
    event: async ({ event }) => {
      const properties = event.properties as any;
      const idle = event.type === "session.status" && properties.status?.type === "idle";
      if (!idle && !["session.idle", "session.error", "session.deleted"].includes(event.type)) return;
      const sessionID = properties.sessionID ?? properties.info?.id;
      if (!sessionID) return;
      for (const key of systems.keys()) if (key.startsWith(`${sessionID}:`)) systems.delete(key);
      for (const key of parameters.keys()) if (key.startsWith(`${sessionID}:`)) parameters.delete(key);
    },
    // Replace Kimaki's generic CLI/orchestration prompt with managed guidance.
    "experimental.chat.system.transform": async (input, output) => {
      // OpenCode retains this array; replacing the wrapper property does not
      // change the instructions its request builder subsequently serializes.
      for (let i = 0; i < output.system.length; i++) {
        output.system[i] = replaceKimakiSystemPrompt(output.system[i]);
      }
      if (input.sessionID) {
        const key = requestKey(input);
        const pending = systems.get(key) ?? new Set<string[]>();
        pending.add(output.system);
        systems.set(key, pending);
      }
    },

    // Kimaki passes its generated Discord prompt through promptAsync's per-call
    // `system` field. Some OpenCode releases do not expose that field through
    // the system transform hook before model dispatch, but the final message
    // transform still sees text parts that are about to reach the model. Keep a
    // second replacement pass here so managed installs do not depend on one
    // experimental hook shape.
    "experimental.chat.messages.transform": async (_input, output) => {
      for (const message of output.messages) {
        const info = message.info as any;
        if (typeof info.system === "string") {
          info.system = replaceKimakiSystemPrompt(info.system);
        }
        for (const part of message.parts) {
          if (part.type !== "text") {
            continue;
          }
          const text = (part as any).text;
          if (typeof text !== "string") {
            continue;
          }
          if (info.role && !(part as any).synthetic && info.role !== "system" && info.role !== "developer") {
            continue;
          }
          (part as any).text = replaceKimakiSystemPrompt(text);
        }
      }
    },

    // Filter out Kimaki's MEMORY.md injection and time-gap MEMORY.md reminders.
    "chat.message": async (_input, output) => {
      if (typeof output.message?.system === "string") {
        output.message.system = replaceKimakiSystemPrompt(output.message.system);
      }
      // Walk backwards so splice indices stay valid.
      for (let i = output.parts.length - 1; i >= 0; i--) {
        const part = output.parts[i];
        if (part.type !== "text" || !(part as any).synthetic) {
          continue;
        }
        const text = (part as any).text as string;
        if (!text) {
          continue;
        }

        // Remove MEMORY.md TOC injection.
        if (text.includes("Project memory from MEMORY.md")) {
          output.parts.splice(i, 1);
          continue;
        }

        // Remove "update MEMORY.md" time-gap reminder.
        if (text.includes("update MEMORY.md before starting the new task")) {
          output.parts.splice(i, 1);
          continue;
        }

      }
    },

    // OAuth request builders carry instructions in provider options rather
    // than system messages. Normalize that independently of the earlier hook.
    "chat.params": async (input, output) => {
      checkSystems(requestKey(input));
      if (typeof input.message?.system === "string") {
        input.message.system = replaceKimakiSystemPrompt(input.message.system);
      }
      if (typeof output.options.instructions === "string") {
        output.options.instructions = replaceKimakiSystemPrompt(output.options.instructions);
      }
      if (input.sessionID) parameters.set(parameterKey(input), output);
    },

    // Headers run after every chat.params plugin. A later plugin that restores
    // generic guidance must stop dispatch, not make an earlier PASS misleading.
    "chat.headers": async (input) => {
      const key = parameterKey(input);
      try {
        checkSystems(requestKey(input));
        const instructions = parameters.get(key)?.options.instructions;
        if (typeof instructions === "string") assertManagedPrompt(instructions);
      } finally {
        parameters.delete(key);
      }
    },

    "experimental.session.compacting": async (_input, output) => {
      for (let i = 0; i < output.context.length; i++) {
        output.context[i] = replaceKimakiSystemPrompt(output.context[i]);
      }
      if (typeof output.prompt === "string") {
        output.prompt = replaceKimakiSystemPrompt(output.prompt);
      }
    },

    "tool.execute.before": async (input, output) => {
      if (input.tool === "bash" && typeof output.args?.command === "string") {
        assertManagedKimakiCommand(output.args.command);
      }
    },
  };
};

// Replace only positively identified Kimaki prompt text. Both transforms use
// this helper because message transforms also receive unrelated text.
function replaceKimakiSystemPrompt(block: string): string {
  const kimakiStart = unmanagedKimakiSystemPromptStart(block);
  if (kimakiStart === -1) {
    return block;
  }

  // Only replace a positively identified Kimaki prompt. Message transforms
  // also see ordinary user and composed AGENTS.md text.
  const prefix = block.slice(0, kimakiStart).trimEnd();
  return [prefix, MANAGED_KIMAKI_SYSTEM_PROMPT].filter(Boolean).join("\n\n");
}

function unmanagedKimakiSystemPromptStart(block: string): number {
  // Canonical bridge text may precede other components' instructions. Mask it
  // without changing offsets so those unrelated suffixes survive normalization.
  const managed = MANAGED_KIMAKI_SYSTEM_PROMPT.trim();
  const candidate = block.split(managed).join(" ".repeat(managed.length));
  const markers = [
    "## Kimaki Discord Bridge",
    "The user is reading your messages from inside Discord, via kimaki.dev",
    "Your current OpenCode session ID is:",
    "## debugging kimaki issues",
    "## uploading files to discord",
  ];

  return markers.reduce((earliest, marker) => {
    const index = candidate.indexOf(marker);
    if (index === -1) {
      return earliest;
    }
    return earliest === -1 ? index : Math.min(earliest, index);
  }, -1);
}

export default fleetContextFilter;

// This is an ownership guard for ordinary CLI launch forms, not a sandbox for
// arbitrary code. Quoted command data (printf, node -e, test fixtures) is inert;
// shell -c/eval launches are inspected as commands instead.
function assertManagedKimakiCommand(command: string, depth = 0): void {
  if (!/kimaki/i.test(command)) return;
  if (depth > 8) throw new Error("Managed command nesting exceeds the ownership guard limit.");
  for (let words of shellCommands(command)) {
    while (words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[0])) words = words.slice(1);
    let executable = words[0]?.split("/").pop();
    if (executable === "env") {
      words = words.slice(1);
      while (words.length && (words[0].startsWith("-") || /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[0]))) {
        if (["-S", "--split-string"].includes(words[0])) {
          assertManagedKimakiCommand(words[1] ?? "", depth + 1);
          words = words.slice(2);
          continue;
        }
        if (words[0].startsWith("--split-string=")) {
          assertManagedKimakiCommand(words[0].slice("--split-string=".length), depth + 1);
        }
        words = words.slice(["-u", "--unset", "-C", "--chdir"].includes(words[0]) ? 2 : 1);
      }
      assertManagedKimakiCommand(words.map(shellQuote).join(" "), depth + 1);
      continue;
    }
    if (["sh", "bash", "zsh", "dash", "fish"].includes(executable ?? "")) {
      const index = words.findIndex(word => /^-[^-]*c/.test(word) || word === "--command");
      if (index !== -1 && words[index + 1]) assertManagedKimakiCommand(words[index + 1], depth + 1);
      continue;
    }
    if (executable === "eval") {
      assertManagedKimakiCommand(words.slice(1).join(" "), depth + 1);
      continue;
    }
    if (["command", "exec", "nohup", "time", "sudo", "timeout"].includes(executable ?? "")) {
      const wrapper = executable;
      words = words.slice(1);
      while (words[0]?.startsWith("-")) {
        words = words.slice(["-u", "-g", "--user", "--group", "-k", "--kill-after"].includes(words[0]) ? 2 : 1);
      }
      if (wrapper === "timeout") words = words.slice(1);
      assertManagedKimakiCommand(words.map(shellQuote).join(" "), depth + 1);
      continue;
    }
    if (["npm", "pnpm", "yarn", "bun"].includes(executable ?? "") && ["exec", "dlx", "x"].includes(words[1])) {
      words = words.slice(1);
      executable = "npx";
    }
    if (["npx", "bunx"].includes(executable ?? "")) {
      words = words.slice(1);
      while (words[0]?.startsWith("-")) {
        if (["-c", "--call"].includes(words[0])) {
          assertManagedKimakiCommand(words[1] ?? "", depth + 1);
          words = [];
          break;
        }
        words = words.slice(["-p", "--package", "--shell"].includes(words[0]) ? 2 : 1);
      }
      executable = words[0]?.split("/").pop();
    }
    if (executable === "node" && /(?:^|\/)kimaki(?:\/|$)/.test(words[1] ?? "")) {
      words = words.slice(1);
      executable = "kimaki";
    }
    if (executable !== "kimaki") continue;
    if (["--help", "-h"].includes(words[2]) || (words[1] === "project" && ["--help", "-h"].includes(words[3]))) continue;
    const deniedSend = words[1] === "send" && (
      !words.includes("--notify-only") || words.some(word => /^--(?:worktree|cwd|thread|session)(?:=|$)/.test(word))
    );
    const deniedProject = words[1] === "project" && ["add", "create"].includes(words[2]);
    if (deniedSend || deniedProject) {
      throw new Error("Managed Kimaki ownership guard: coding sessions, projects, and worktrees belong to the composed managed runtime. Use Homeboy's tracked workspace/task route; Kimaki remains the Discord bridge. Notification-only sends, uploads, and explicit archive operations remain available.");
    }
  }
}

function assertManagedPrompt(block: string): void {
  if (unmanagedKimakiSystemPromptStart(block) !== -1) {
    throw new Error("Managed Kimaki dispatch guard: generic instruction context was reintroduced after filtering. Dispatch refused; inspect active plugin ordering and request assembly. No prompt contents were logged.");
  }
}

function shellQuote(word: string): string {
  return "'" + word.replace(/'/g, "'\\''") + "'";
}

function shellCommands(command: string): string[][] {
  const commands: string[][] = [];
  let words: string[] = [], word = "", quote = "", escaped = false;
  const flushWord = () => { if (word) words.push(word); word = ""; };
  const flushCommand = () => { flushWord(); if (words.length) commands.push(words); words = []; };
  for (let i = 0; i < command.length; i++) {
    const char = command[i];
    if (escaped) { word += char; escaped = false; continue; }
    if (char === "\\" && quote !== "'") { escaped = true; continue; }
    if (char === "`" && quote !== "'") {
      let end = i + 1;
      for (; end < command.length; end++) {
        if (command[end] === "\\") { end++; continue; }
        if (command[end] === "`") break;
      }
      if (end === command.length) throw new Error("Managed command ownership check requires complete command substitution.");
      commands.push(...shellCommands(command.slice(i + 1, end)));
      word += "substitution";
      i = end;
      continue;
    }
    if (char === "$" && command[i + 1] === "(" && quote !== "'") {
      let nesting = 1, innerQuote = "", innerEscape = false, end = i + 2;
      for (; end < command.length; end++) {
        const inner = command[end];
        if (innerEscape) { innerEscape = false; continue; }
        if (inner === "\\" && innerQuote !== "'") { innerEscape = true; continue; }
        if (innerQuote) { if (inner === innerQuote) innerQuote = ""; continue; }
        if (inner === "'" || inner === '"') { innerQuote = inner; continue; }
        if (inner === "(") nesting++;
        if (inner === ")" && --nesting === 0) break;
      }
      if (nesting !== 0) throw new Error("Managed command ownership check requires complete command substitution.");
      commands.push(...shellCommands(command.slice(i + 2, end)));
      word += "substitution";
      i = end;
      continue;
    }
    if (quote) {
      if (char === quote) quote = "";
      else word += char;
      continue;
    }
    if (char === "'" || char === '"') { quote = char; continue; }
    if (char === "#" && !word) { while (i < command.length && command[i] !== "\n") i++; flushCommand(); continue; }
    if (";|&\n".includes(char)) { flushCommand(); continue; }
    if (/\s/.test(char)) { flushWord(); continue; }
    word += char;
  }
  if (quote || escaped) throw new Error("Managed command ownership check requires complete shell quoting.");
  flushCommand();
  return commands;
}
