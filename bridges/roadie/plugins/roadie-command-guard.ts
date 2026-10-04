// roadie-command-guard.ts — keep coding sessions on the managed runtime.
//
// Agents on a wp-coding-agents install start coding work through Homeboy's
// tracked workspace/task route. This OpenCode plugin refuses bash commands
// that would bypass it through the bridge: `roadie send` that starts a
// session (anything but --notify-only, or targeting --cwd/--thread/--session/
// --worktree) and `roadie project add|create`. Notification-only sends,
// uploads and archive operations stay available. It is an ownership guard for
// ordinary CLI launch forms, not a sandbox.

import type { Plugin } from "@opencode-ai/plugin";

const roadieCommandGuard: Plugin = async () => ({
  "tool.execute.before": async (input, output) => {
    if (input.tool === "bash" && typeof output.args?.command === "string") {
      assertManagedRoadieCommand(output.args.command);
    }
  },
});

export default roadieCommandGuard;

// This is an ownership guard for ordinary CLI launch forms, not a sandbox for
// arbitrary code. Quoted command data (printf, node -e, test fixtures) is inert;
// shell -c/eval launches are inspected as commands instead.
function assertManagedRoadieCommand(command: string, depth = 0): void {
  if (!/roadie/i.test(command)) return;
  if (depth > 8) throw new Error("Managed command nesting exceeds the ownership guard limit.");
  for (let words of shellCommands(stripHeredocBodies(command))) {
    while (words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[0])) words = words.slice(1);
    let executable = words[0]?.split("/").pop();
    if (executable === "env") {
      words = words.slice(1);
      while (words.length && (words[0].startsWith("-") || /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[0]))) {
        if (["-S", "--split-string"].includes(words[0])) {
          assertManagedRoadieCommand(words[1] ?? "", depth + 1);
          words = words.slice(2);
          continue;
        }
        if (words[0].startsWith("--split-string=")) {
          assertManagedRoadieCommand(words[0].slice("--split-string=".length), depth + 1);
        }
        words = words.slice(["-u", "--unset", "-C", "--chdir"].includes(words[0]) ? 2 : 1);
      }
      assertManagedRoadieCommand(words.map(shellQuote).join(" "), depth + 1);
      continue;
    }
    if (["sh", "bash", "zsh", "dash", "fish"].includes(executable ?? "")) {
      const index = words.findIndex(word => /^-[^-]*c/.test(word) || word === "--command");
      if (index !== -1 && words[index + 1]) assertManagedRoadieCommand(words[index + 1], depth + 1);
      continue;
    }
    if (executable === "eval") {
      assertManagedRoadieCommand(words.slice(1).join(" "), depth + 1);
      continue;
    }
    if (["command", "exec", "nohup", "time", "sudo", "timeout"].includes(executable ?? "")) {
      const wrapper = executable;
      words = words.slice(1);
      while (words[0]?.startsWith("-")) {
        words = words.slice(["-u", "-g", "--user", "--group", "-k", "--kill-after"].includes(words[0]) ? 2 : 1);
      }
      if (wrapper === "timeout") words = words.slice(1);
      assertManagedRoadieCommand(words.map(shellQuote).join(" "), depth + 1);
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
          assertManagedRoadieCommand(words[1] ?? "", depth + 1);
          words = [];
          break;
        }
        words = words.slice(["-p", "--package", "--shell"].includes(words[0]) ? 2 : 1);
      }
      executable = words[0]?.split("/").pop();
    }
    if (executable === "node" && /(?:^|\/)roadie(?:\/|$)/.test(words[1] ?? "")) {
      words = words.slice(1);
      executable = "roadie";
    }
    if (executable !== "roadie") continue;
    if (["--help", "-h"].includes(words[2]) || (words[1] === "project" && ["--help", "-h"].includes(words[3]))) continue;
    const deniedSend = words[1] === "send" && (
      !words.includes("--notify-only") || words.some(word => /^--(?:worktree|cwd|thread|session)(?:=|$)/.test(word))
    );
    const deniedProject = words[1] === "project" && ["add", "create"].includes(words[2]);
    if (deniedSend || deniedProject) {
      throw new Error("Managed Roadie ownership guard: coding sessions, projects, and worktrees belong to the composed managed runtime. Use Homeboy's tracked workspace/task route; Roadie remains the Discord bridge. Notification-only sends, uploads, and explicit archive operations remain available.");
    }
  }
}

function shellQuote(word: string): string {
  return "'" + word.replace(/'/g, "'\\''") + "'";
}

// Heredoc bodies are data (commit messages, PR bodies, file contents): an
// apostrophe in prose there is not an open quote. Drop each body, keeping the
// command line. An unquoted heredoc still expands $(...) and backticks, so
// those substitutions are kept as commands and inspected like any other.
function stripHeredocBodies(command: string): string {
  const lines = command.split("\n");
  const out: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    out.push(line);
    for (const [, dash, quote, tag] of line.matchAll(/<<(-?)\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\2/g)) {
      const expands = quote === "";
      while (i + 1 < lines.length) {
        const body = lines[++i];
        if ((dash ? body.replace(/^\t+/, "") : body) === tag) break;
        if (expands) {
          for (const sub of body.match(/\$\([^()]*\)|`[^`]*`/g) ?? []) out.push(sub);
        }
      }
    }
  }
  return out.join("\n");
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
