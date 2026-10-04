// tests/roadie-command-guard.mjs — the managed-runtime ownership guard.
//
// Coding sessions, projects and worktrees belong to Homeboy's tracked route,
// so an agent's bash tool must not start them through `roadie send` or
// `roadie project add|create`. Notification-only sends stay available.
import assert from "node:assert/strict";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const pluginPath = resolve(import.meta.dirname, "../bridges/roadie/plugins/roadie-command-guard.ts");
const hooks = await (await import(pathToFileURL(pluginPath).href)).default({});
const before = hooks["tool.execute.before"];

const run = command => before({ tool: "bash" }, { args: { command } });
const denied = async command => assert.rejects(run(command), /ownership guard|requires complete/, `should refuse: ${command}`);
const allowed = async command => assert.doesNotReject(run(command), `should allow: ${command}`);

for (const command of [
  "roadie send --channel 123 --prompt 'build it'",
  "roadie send --notify-only --channel 1 --prompt hi --worktree x",
  "roadie send --notify-only --cwd /tmp --prompt hi",
  "roadie send --notify-only --thread=1 --prompt hi",
  "roadie project add /tmp/x",
  "roadie project create demo",
  "/usr/local/lib/wp-coding-agents/roadie/bin/roadie send --prompt x",
  "FOO=1 roadie send --prompt x",
  "env -u HOME roadie send --prompt x",
  "env -S 'roadie send --prompt x'",
  "bash -c 'roadie send --prompt x'",
  "sh -lc \"roadie send --prompt x\"",
  "eval roadie send --prompt x",
  "sudo -u opencode roadie send --prompt x",
  "timeout 5 roadie send --prompt x",
  "npx roadie send --prompt x",
  "pnpm exec roadie send --prompt x",
  "npx -c 'roadie send --prompt x'",
  "node /usr/lib/node_modules/@extrachill/roadie/bin.js send --prompt x",
  "echo $(roadie send --prompt x)",
  "echo `roadie send --prompt x`",
  "true && roadie send --prompt x",
  "true; roadie project add .",
  "roadie send --prompt 'unterminated",
]) await denied(command);

for (const command of [
  "roadie send --notify-only --channel 123 --prompt 'deploy finished'",
  "roadie send --help",
  "roadie project --help",
  "roadie project list",
  "roadie upload-to-discord file.png",
  "roadie session archive --thread 1",
  "printf 'roadie send --prompt x'",
  "node -e \"console.log('roadie send --prompt x')\"",
  "echo roadie",
  "git status",
]) await allowed(command);

await assert.doesNotReject(before({ tool: "read" }, { args: { command: "roadie send --prompt x" } }), "non-bash tools are ignored");
console.log("PASS: tests/roadie-command-guard.mjs");
