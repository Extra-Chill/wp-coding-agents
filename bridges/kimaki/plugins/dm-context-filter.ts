// dm-context-filter.ts — OpenCode plugin for WordPress agent VPSes with Data Machine.
//
// Replaces Kimaki's built-in system prompt on managed installs. Kimaki remains
// the Discord bridge and human coordination surface; Homeboy owns task/lab
// orchestration and preview/tunnel lifecycle; Data Machine Code owns repository
// workspace/worktree lifecycle.
//
// The replacement prompt is deliberately small. Repository, agent memory,
// scheduling, worktree, and Homeboy lab instructions come from the composed
// Data Machine/AGENTS instruction stack, not from Kimaki's generic CLI prompt.
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

Homeboy owns coding task orchestration, lab execution, durable task state, queues, retries, logs, artifacts, promotion, previews, and tunnel lifecycle. Use the Homeboy guidance from AGENTS.md for offloaded coding work, lab runs, preview URLs, and evidence.

Data Machine Code owns repository checkout and worktree lifecycle under the configured workspace root. Use the Data Machine Code guidance from AGENTS.md for repository/worktree operations.

## Bridge Diagnostics

For Kimaki bridge failures, inspect \`$HOME/.kimaki/kimaki.log\`. The log is reset every time Kimaki restarts, so it only covers the current run.
`;

const fleetContextFilter: Plugin = async () => {
  return {
    // Replace Kimaki's generic CLI/orchestration prompt with managed guidance.
    "experimental.chat.system.transform": async (_input, output) => {
      output.system = [MANAGED_KIMAKI_SYSTEM_PROMPT];
    },

    // Filter out Kimaki's MEMORY.md injection and time-gap MEMORY.md reminders.
    "chat.message": async (_input, output) => {
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
  };
};

export default fleetContextFilter;
